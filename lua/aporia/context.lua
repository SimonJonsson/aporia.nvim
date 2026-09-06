local M = { staged = {} }

local function display_path(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name ~= "" and vim.fn.fnamemodify(name, ":~:.") or "[No Name]"
end

local function build(kind, bufnr, sel_from, sel_to, from, to)
  local opts = require("aporia.config").options.context
  local lines = vim.api.nvim_buf_get_lines(bufnr, from - 1, to, false)
  local truncated = ""
  if #lines > opts.max_lines then
    lines = vim.list_slice(lines, 1, opts.max_lines)
    truncated = ", truncated to " .. opts.max_lines .. " lines"
  end
  local header
  if kind == "buffer" then
    header = string.format("From `%s` (whole buffer%s)", display_path(bufnr), truncated)
  else
    header = string.format(
      "From `%s` (selection lines %d-%d, shown with context %d-%d%s)",
      display_path(bufnr),
      sel_from,
      sel_to,
      from,
      to,
      truncated
    )
  end
  local short
  if kind == "buffer" then
    short = display_path(bufnr)
  else
    short = display_path(bufnr) .. " " .. sel_from .. "-" .. sel_to
  end
  local block = header .. "\n```" .. vim.bo[bufnr].filetype .. "\n" .. table.concat(lines, "\n") .. "\n```"
  return { header = header, block = block, count = #lines, short = short }
end

local function selection_range(bufnr)
  if vim.fn.mode():match("^%s*[vV]") and vim.api.nvim_get_current_buf() == bufnr then
    local s = vim.fn.line("v")
    local e = vim.fn.line(".")
    if s > e then
      s, e = e, s
    end
    return s, e
  end
  local s = vim.fn.line("'<")
  local e = vim.fn.line("'>")
  if s <= 0 or e < s then
    return nil
  end
  return s, e
end

function M.capture_current()
  local bufnr = vim.api.nvim_get_current_buf()
  local opts = require("aporia.config").options.context
  local s, e = selection_range(bufnr)
  if s then
    local total = vim.api.nvim_buf_line_count(bufnr)
    return build("selection", bufnr, s, e, math.max(1, s - opts.padding), math.min(total, e + opts.padding))
  end
  return build("buffer", bufnr, nil, nil, 1, vim.api.nvim_buf_line_count(bufnr))
end

function M.stage_selection()
  local bufnr = vim.api.nvim_get_current_buf()
  local opts = require("aporia.config").options.context
  local s, e = selection_range(bufnr)
  if not s then
    vim.notify("aporia: no visual selection", vim.log.levels.WARN)
    return false
  end
  local total = vim.api.nvim_buf_line_count(bufnr)
  local item = build("selection", bufnr, s, e, math.max(1, s - opts.padding), math.min(total, e + opts.padding))
  table.insert(M.staged, item)
  local chat = package.loaded["aporia.chat"]
  if chat then
    chat.render()
  end
  vim.notify("aporia: staged " .. item.header)
  return true
end

function M.stage_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  local item = build("buffer", bufnr, nil, nil, 1, vim.api.nvim_buf_line_count(bufnr))
  table.insert(M.staged, item)
  local chat = package.loaded["aporia.chat"]
  if chat then
    chat.render()
  end
  vim.notify("aporia: staged " .. item.header)
end

function M.stage_doc(url, text)
  local lines = vim.split(text, "\n")
  local truncated = ""
  if #lines > 400 then
    lines = vim.list_slice(lines, 1, 400)
    truncated = ", truncated to 400 lines"
  end
  local header = string.format("Fetched doc: %s (%d lines%s)", url, #lines, truncated)
  local block = header .. "\n```\n" .. table.concat(lines, "\n") .. "\n```"
  table.insert(M.staged, { header = header, block = block, count = #lines, short = url })
  local chat = package.loaded["aporia.chat"]
  if chat then
    chat.render()
  end
  vim.notify("aporia: staged " .. header)
end

function M.summary()
  local blocks, lines = #M.staged, 0
  for _, item in ipairs(M.staged) do
    lines = lines + item.count
  end
  return blocks, lines
end

function M.consume_blocks()
  if #M.staged == 0 then
    return {}
  end
  local blocks = M.staged
  M.staged = {}
  return blocks
end

function M.consume()
  local parts = {}
  for _, item in ipairs(M.consume_blocks()) do
    parts[#parts + 1] = item.block
  end
  return table.concat(parts, "\n\n")
end

function M.clear()
  M.staged = {}
end

function M.unstage(line)
  local index = line <= 2 and #M.staged or line - 2
  local item = table.remove(M.staged, index)
  if item then
    local chat = package.loaded["aporia.chat"]
    if chat then
      chat.render()
    end
    vim.notify("aporia: unstaged " .. item.header)
  end
end

function M.headers()
  local out = {}
  for _, item in ipairs(M.staged) do
    out[#out + 1] = item.short or item.header
  end
  return out
end

return M
