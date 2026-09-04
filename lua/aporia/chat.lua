local M = {
  bufnr = nil,
  winid = nil,
  messages = {},
  busy = false,
  _input_start = 1,
}

local GENERATING = "Generating response…"
local ICONS = { user = "❯", tutor = "◆", staged = "◇" }
local INPUT_PREFIX = "❯ "
local HINT = "type below · <CR> send · <C-j> newline · q hide"
local NS = vim.api.nvim_create_namespace("aporia")

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "aporia" })
end

local function set_highlights()
  local groups = {
    AporiaWinBar = { link = "Title", bold = true },
    AporiaUser = { link = "Question" },
    AporiaTutor = { link = "Special" },
    AporiaStaged = { link = "Comment" },
    AporiaSep = { link = "Comment" },
    AporiaHint = { link = "Comment" },
  }
  for name, def in pairs(groups) do
    vim.api.nvim_set_hl(0, name, def)
  end
end

local function sep_line()
  local width = 80
  if M.winid and vim.api.nvim_win_is_valid(M.winid) then
    width = vim.api.nvim_win_get_width(M.winid)
  end
  return string.rep("─", math.max(width, 20))
end

local function render()
  local out = {}
  local hls = {}

  local function add(line, hl_group)
    out[#out + 1] = line
    if hl_group then
      hls[#out] = hl_group
    end
  end

  if #M.messages == 0 then
    add("")
    add("Nothing is sent until you press <CR>.", "AporiaHint")
  end

  for _, m in ipairs(M.messages) do
    out[#out + 1] = ""
    if m.role == "user" then
      add(ICONS.user .. " You · " .. m.time, "AporiaUser")
    else
      add(ICONS.tutor .. " Tutor · " .. m.time, "AporiaTutor")
    end
    vim.list_extend(out, vim.split(m.content, "\n"))
  end

  local headers = require("aporia.context").headers()
  if #headers > 0 then
    out[#out + 1] = ""
    add(ICONS.staged .. " staged context (sent with your next message)", "AporiaStaged")
    for _, h in ipairs(headers) do
      add("  - " .. h, "AporiaStaged")
    end
  end

  out[#out + 1] = ""
  add(sep_line(), "AporiaSep")
  add(INPUT_PREFIX)
  add(HINT, "AporiaHint")

  M._input_start = #out - 1

  vim.api.nvim_buf_set_lines(M.bufnr, 0, -1, false, out)
  vim.api.nvim_buf_clear_namespace(M.bufnr, NS, 0, -1)
  for line, hl_group in pairs(hls) do
    vim.api.nvim_buf_set_extmark(M.bufnr, NS, line - 1, 0, {
      end_row = line,
      hl_eol = true,
      hl_group = hl_group,
    })
  end

  if M.winid and vim.api.nvim_win_is_valid(M.winid) then
    vim.api.nvim_win_set_cursor(M.winid, { #out - 1, #INPUT_PREFIX })
  end
end

function M.open()
  set_highlights()
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
  vim.wo[M.winid].winbar = "%#AporiaWinBar#%= ✦ aporia %=%#AporiaHint#q hide "
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
  if lines[#lines] == HINT then
    lines[#lines] = nil
  end
  lines[1] = lines[1] or ""
  lines[1] = lines[1]:gsub("^" .. vim.pesc(INPUT_PREFIX), "", 1)
  local text = vim.trim(table.concat(lines, "\n"))
  if text == "" then
    return
  end
  local block = require("aporia.context").consume()
  if block ~= "" then
    text = text .. "\n\n" .. block
  end
  table.insert(M.messages, { role = "user", content = text, time = os.date("%H:%M") })
  M._request()
end

function M._request(opts)
  opts = opts or {}
  M.busy = true
  table.insert(M.messages, { role = "assistant", content = GENERATING, time = os.date("%H:%M") })
  render()
  local prompts = require("aporia.prompts")
  local msgs = { { role = "system", content = prompts.system_prompt } }
  vim.list_extend(msgs, M.messages)
  require("aporia.http").request(msgs, function(err, content)
    M.busy = false
    if err then
      M.messages[#M.messages] = { role = "assistant", content = "ERROR: " .. err, time = os.date("%H:%M") }
      render()
      return notify(err, vim.log.levels.ERROR)
    end
    M.messages[#M.messages] = { role = "assistant", content = content, time = os.date("%H:%M") }
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
  table.insert(M.messages, { role = "user", content = msg, time = os.date("%H:%M") })
  if name == "log" then
    M._request({ on_reply = function(content)
      require("aporia.log").run(content)
    end })
  else
    M._request()
  end
end

return M
