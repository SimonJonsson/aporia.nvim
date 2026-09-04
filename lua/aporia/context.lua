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
  local block = header .. "\n```" .. vim.bo[bufnr].filetype .. "\n" .. table.concat(lines, "\n") .. "\n```"
  return { header = header, block = block }
end

local function selection_range(bufnr)
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
    return vim.notify("aporia: no visual selection", vim.log.levels.WARN)
  end
  local total = vim.api.nvim_buf_line_count(bufnr)
  local item = build("selection", bufnr, s, e, math.max(1, s - opts.padding), math.min(total, e + opts.padding))
  table.insert(M.staged, item)
  vim.notify("aporia: staged " .. item.header)
end

function M.stage_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  local item = build("buffer", bufnr, nil, nil, 1, vim.api.nvim_buf_line_count(bufnr))
  table.insert(M.staged, item)
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
  table.insert(M.staged, { header = header, block = block })
  vim.notify("aporia: staged " .. header)
end

function M.consume()
  if #M.staged == 0 then
    return ""
  end
  local blocks = {}
  for _, item in ipairs(M.staged) do
    blocks[#blocks + 1] = item.block
  end
  M.staged = {}
  return table.concat(blocks, "\n\n")
end

function M.clear()
  M.staged = {}
end

function M.headers()
  local out = {}
  for _, item in ipairs(M.staged) do
    out[#out + 1] = item.header
  end
  return out
end

return M
