local SEP = "───── input below · <CR> send · <C-j> newline · q hide ─────"

local M = {
  bufnr = nil,
  winid = nil,
  messages = {},
  busy = false,
  _input_start = 1,
}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "aporia" })
end

local function render()
  local out = { "# aporia", "" }
  if #M.messages == 0 then
    out[#out + 1] = "Your tutor is listening. Nothing is sent until you press <CR>."
  end
  for _, m in ipairs(M.messages) do
    out[#out + 1] = ""
    out[#out + 1] = m.role == "user" and "## You" or "## Tutor"
    vim.list_extend(out, vim.split(m.content, "\n"))
  end
  local headers = require("aporia.context").headers()
  if #headers > 0 then
    out[#out + 1] = ""
    out[#out + 1] = "### staged context (sent with your next message)"
    for _, h in ipairs(headers) do
      out[#out + 1] = "- " .. h
    end
  end
  out[#out + 1] = ""
  out[#out + 1] = SEP
  out[#out + 1] = ""
  M._input_start = #out + 1
  vim.api.nvim_buf_set_lines(M.bufnr, 0, -1, false, out)
  if M.winid and vim.api.nvim_win_is_valid(M.winid) then
    vim.api.nvim_win_set_cursor(M.winid, { #out, 0 })
  end
end

function M.open()
  if not (M.bufnr and vim.api.nvim_buf_is_valid(M.bufnr)) then
    M.bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[M.bufnr].filetype = "markdown"
    vim.bo[M.bufnr].buftype = "nofile"
    vim.bo[M.bufnr].swapfile = false
    local buf_opts = { buffer = M.bufnr, silent = true }
    vim.keymap.set({ "n", "i" }, "<CR>", function()
      M.submit()
    end, buf_opts)
    vim.keymap.set("i", "<C-j>", "<CR>", buf_opts)
    vim.keymap.set("n", "q", function()
      M.hide()
    end, buf_opts)
    pcall(vim.treesitter.start, M.bufnr, "markdown")
  end
  render()
  if M.winid and vim.api.nvim_win_is_valid(M.winid) then
    vim.api.nvim_set_current_win(M.winid)
    return
  end
  local width = math.floor(vim.o.columns * require("aporia.config").options.window.width)
  vim.cmd("botright " .. width .. "vsplit")
  M.winid = vim.api.nvim_get_current_win()
  vim.wo[M.winid].wrap = true
  vim.api.nvim_win_set_buf(M.winid, M.bufnr)
  vim.cmd("startinsert")
end

function M.hide()
  if M.winid and vim.api.nvim_win_is_valid(M.winid) then
    vim.api.nvim_win_close(M.winid, true)
  end
  M.winid = nil
end

function M.toggle()
  if M.winid and vim.api.nvim_win_is_valid(M.winid) then
    M.hide()
  else
    M.open()
  end
end

function M.reset()
  M.messages = {}
  require("aporia.context").clear()
  if M.bufnr and vim.api.nvim_buf_is_valid(M.bufnr) then
    render()
  end
  notify("aporia: session reset")
end

function M.submit()
  if M.busy then
    return notify("aporia: waiting for the tutor", vim.log.levels.WARN)
  end
  local lines = vim.api.nvim_buf_get_lines(M.bufnr, M._input_start - 1, -1, false)
  local text = vim.trim(table.concat(lines, "\n"))
  if text == "" then
    return
  end
  local block = require("aporia.context").consume()
  if block ~= "" then
    text = text .. "\n\n" .. block
  end
  table.insert(M.messages, { role = "user", content = text })
  M._request()
end

function M._request(opts)
  opts = opts or {}
  M.busy = true
  table.insert(M.messages, { role = "assistant", content = "*thinking…*" })
  render()
  local prompts = require("aporia.prompts")
  local msgs = { { role = "system", content = prompts.system_prompt } }
  vim.list_extend(msgs, M.messages)
  require("aporia.http").request(msgs, function(err, content)
    M.busy = false
    if err then
      M.messages[#M.messages] = { role = "assistant", content = "ERROR: " .. err }
      render()
      return notify(err, vim.log.levels.ERROR)
    end
    M.messages[#M.messages] = { role = "assistant", content = content }
    render()
    require("aporia.fetch").process(content)
    if opts.on_reply then
      opts.on_reply(content)
    end
  end)
end

function M.trap(name)
  local t = require("aporia.prompts").traps[name]
  if not t then
    return notify("unknown trap: " .. tostring(name), vim.log.levels.WARN)
  end
  local input = t.ask and vim.trim(vim.fn.input(t.ask .. ": ")) or ""
  local block = require("aporia.context").capture_current()
  local msg = t.template:gsub("{input}", function()
    return input
  end)
  msg = msg:gsub("{selection}", function()
    return block.block
  end)
  M.open()
  table.insert(M.messages, { role = "user", content = msg })
  if name == "log" then
    M._request({ on_reply = function(content)
      require("aporia.log").run(content)
    end })
  else
    M._request()
  end
end

return M
