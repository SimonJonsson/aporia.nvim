local M = {
  bufnr = nil,
  winid = nil,
  input_bufnr = nil,
  input_winid = nil,
  staged_bufnr = nil,
  staged_winid = nil,
  messages = {},
  busy = false,
}

local GENERATING = "Generating response…"
local ICONS = { user = "❯", tutor = "◆", staged = "◇" }
local INPUT_HEIGHT = 6
local STAGED_MAX_LINES = 8
local NS = vim.api.nvim_create_namespace("aporia")
local NS_INPUT = vim.api.nvim_create_namespace("aporia_input")

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "aporia" })
end

local function set_highlights()
  local groups = {
    AporiaWinBar = { link = "Title", bold = true },
    AporiaUser = { link = "Question" },
    AporiaTutor = { link = "Special" },
    AporiaStaged = { link = "Comment" },
    AporiaHint = { link = "Comment" },
    AporiaAccent = { link = "Keyword" },
    AporiaInputTitle = { link = "Title" },
    AporiaBorder = { link = "Comment" },
  }
  for name, def in pairs(groups) do
    vim.api.nvim_set_hl(0, name, def)
  end
end

local function geometry()
  local width = math.floor(vim.o.columns * require("aporia.config").options.window.width)
  local tabline_h = (vim.o.showtabline == 2 or (vim.o.showtabline == 1 and vim.fn.tabpagenr("$") > 1)) and 1 or 0
  local statusline_h = vim.o.laststatus > 0 and 1 or 0
  local usable = vim.o.lines - vim.o.cmdheight - statusline_h - tabline_h
  return {
    row = tabline_h,
    col = vim.o.columns - width,
    width = width,
    usable = usable,
  }
end

local open_chat_float, open_staged_float, open_input_float, create_staged_buffer

local function layout(blocks, header_count)
  local g = geometry()
  local staged_text_h = 0
  local staged_h = 0
  if blocks > 0 then
    staged_text_h = math.min(header_count + 2, STAGED_MAX_LINES)
    staged_h = staged_text_h
  end
  local staged_visual = staged_h > 0 and (staged_h + 2) or 0
  local chat_h = math.max(g.usable - staged_visual - INPUT_HEIGHT - 6, 4)

  if M.winid and vim.api.nvim_win_is_valid(M.winid) then
    vim.api.nvim_win_set_config(M.winid, {
      relative = "editor",
      row = g.row,
      col = g.col,
      width = g.width,
      height = chat_h,
    })
  else
    open_chat_float(g, chat_h)
  end

  if blocks > 0 then
    if not (M.staged_bufnr and vim.api.nvim_buf_is_valid(M.staged_bufnr)) then
      create_staged_buffer()
    end
    if M.staged_winid and vim.api.nvim_win_is_valid(M.staged_winid) then
      vim.api.nvim_win_set_config(M.staged_winid, {
        relative = "editor",
        row = g.row + chat_h + 2,
        col = g.col,
        width = g.width,
        height = staged_h,
      })
    else
      open_staged_float(g, g.row + chat_h + 2, staged_h)
    end
  elseif M.staged_winid and vim.api.nvim_win_is_valid(M.staged_winid) then
    vim.api.nvim_win_close(M.staged_winid, true)
    M.staged_winid = nil
  end

  if M.input_winid and vim.api.nvim_win_is_valid(M.input_winid) then
    vim.api.nvim_win_set_config(M.input_winid, {
      relative = "editor",
      row = g.row + chat_h + 2 + staged_h + 2,
      col = g.col,
      width = g.width,
      height = INPUT_HEIGHT,
    })
  else
    open_input_float(g, g.row + chat_h + 2 + staged_h + 2)
  end
end

M.geometry = geometry

local function render_chat()
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
    add("Nothing is sent until you press <CR> in the input box.", "AporiaHint")
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

  local content_height = M.winid
    and vim.api.nvim_win_is_valid(M.winid)
    and vim.api.nvim_win_get_height(M.winid)
    or 30
  local pad = math.max(0, content_height - #out)
  local padded = {}
  for _ = 1, pad do
    padded[#padded + 1] = ""
  end
  vim.list_extend(padded, out)

  vim.bo[M.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(M.bufnr, 0, -1, false, padded)
  vim.bo[M.bufnr].modifiable = false
  vim.api.nvim_buf_clear_namespace(M.bufnr, NS, 0, -1)
  for line, hl_group in pairs(hls) do
    vim.api.nvim_buf_set_extmark(M.bufnr, NS, line + pad - 1, 0, {
      end_row = line + pad,
      hl_eol = true,
      hl_group = hl_group,
    })
  end
end
local function render_staged(blocks, staged_lines, headers)
  if not (M.staged_bufnr and vim.api.nvim_buf_is_valid(M.staged_bufnr)) then
    return
  end
  local out = {}
  if blocks > 0 then
    out[#out + 1] = "▢ staged · d unstage · sent with your next message"
    out[#out + 1] = ICONS.staged
      .. string.format(
        " staged: %d block%s · %d lines%s",
        blocks,
        blocks == 1 and "" or "s",
        staged_lines,
        #headers > STAGED_MAX_LINES - 2 and ("  (+" .. (#headers - (STAGED_MAX_LINES - 2)) .. " more)") or ""
      )
    for i, h in ipairs(headers) do
      if #out >= STAGED_MAX_LINES then
        break
      end
      out[#out + 1] = "  " .. h
    end
  end
  vim.bo[M.staged_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(M.staged_bufnr, 0, -1, false, out)
  vim.bo[M.staged_bufnr].modifiable = false
end

function M.render()
  set_highlights()
  local context = require("aporia.context")
  local blocks, staged_lines = context.summary()
  local headers = context.headers()
  layout(blocks, #headers)
  render_chat()
  render_staged(blocks, staged_lines, headers)
end

local function create_chat_buffer()
  M.bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[M.bufnr].filetype = "markdown"
  vim.bo[M.bufnr].buftype = "nofile"
  vim.bo[M.bufnr].swapfile = false
  vim.bo[M.bufnr].textwidth = 0
  vim.bo[M.bufnr].formatoptions = ""
  vim.keymap.set("n", "q", function()
    M.hide()
  end, { buffer = M.bufnr, silent = true })
  pcall(vim.treesitter.start, M.bufnr, "markdown")
end

local function set_input_hint()
  if not (M.input_bufnr and vim.api.nvim_buf_is_valid(M.input_bufnr)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(M.input_bufnr, NS_INPUT, 0, -1)
  local last = vim.api.nvim_buf_line_count(M.input_bufnr) - 1
  vim.api.nvim_buf_set_extmark(M.input_bufnr, NS_INPUT, last, 0, {
    virt_lines = { { { " <CR> send · <C-j> newline · esc leaves insert", "AporiaHint" } } },
  })
end

local function create_input_buffer()
  M.input_bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[M.input_bufnr].buftype = "nofile"
  vim.bo[M.input_bufnr].swapfile = false
  vim.bo[M.input_bufnr].textwidth = 0
  vim.bo[M.input_bufnr].formatoptions = ""
  set_input_hint()
  local opts = { buffer = M.input_bufnr, silent = true }
  vim.keymap.set({ "n", "i" }, "<CR>", function()
    M.submit()
  end, opts)
  vim.keymap.set("i", "<C-j>", "<CR>", opts)
  vim.keymap.set("n", "q", function()
    M.hide()
  end, opts)
end

function create_staged_buffer()
  M.staged_bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[M.staged_bufnr].buftype = "nofile"
  vim.bo[M.staged_bufnr].swapfile = false
  vim.keymap.set("n", "d", function()
    require("aporia.context").unstage(vim.fn.line(".") - 1)
    M.render()
  end, { buffer = M.staged_bufnr, silent = true })
  vim.keymap.set("n", "q", function()
    M.hide()
  end, { buffer = M.staged_bufnr, silent = true })
end

function open_chat_float(g, height)
  M.winid = vim.api.nvim_open_win(M.bufnr, false, {
    relative = "editor",
    row = g.row,
    col = g.col,
    width = g.width,
    height = height,
    border = "rounded",
    style = "minimal",
    zindex = 40,
  })
  local wo = vim.wo[M.winid]
  wo.wrap = true
  wo.spell = false
  wo.list = false
  wo.cursorline = false
  wo.winbar = "%#AporiaWinBar#%= ✦ aporia %=%#AporiaHint#q hide "
  wo.winhighlight = "FloatBorder:AporiaBorder,Normal:Normal"
end

function open_staged_float(g, row, height)
  M.staged_winid = vim.api.nvim_open_win(M.staged_bufnr, false, {
    relative = "editor",
    row = row,
    col = g.col,
    width = g.width,
    height = height,
    border = "rounded",
    style = "minimal",
    zindex = 40,
  })
  local wo = vim.wo[M.staged_winid]
  wo.spell = false
  wo.list = false
  wo.cursorline = false
  wo.winhighlight = "FloatBorder:AporiaBorder,Normal:NormalFloat"
end

function open_input_float(g, row)
  local config = require("aporia.config").options
  local p = config.providers[config.provider] or {}
  local label = p.model ~= "" and p.model or config.provider
  M.input_winid = vim.api.nvim_open_win(M.input_bufnr, false, {
    relative = "editor",
    row = row,
    col = g.col,
    width = g.width,
    height = INPUT_HEIGHT,
    border = "rounded",
    style = "minimal",
    zindex = 41,
  })
  local wo = vim.wo[M.input_winid]
  wo.spell = false
  wo.list = false
  wo.cursorline = false
  wo.colorcolumn = ""
  wo.statuscolumn = "%#AporiaAccent#▌ "
  wo.winbar = "%#AporiaInputTitle# ▢ %#AporiaWinBar#Tutor · " .. label .. " "
  wo.winhighlight = "FloatBorder:AporiaBorder,Normal:NormalFloat"
end

function M.open()
  set_highlights()
  if not (M.bufnr and vim.api.nvim_buf_is_valid(M.bufnr)) then
    create_chat_buffer()
  end
  if not (M.input_bufnr and vim.api.nvim_buf_is_valid(M.input_bufnr)) then
    create_input_buffer()
  end
  if M.winid and vim.api.nvim_win_is_valid(M.winid) and M.input_winid and vim.api.nvim_win_is_valid(M.input_winid) then
    vim.api.nvim_set_current_win(M.input_winid)
    vim.cmd("startinsert!")
    return
  end
  M.hide()
  M.render()
  vim.api.nvim_set_current_win(M.input_winid)
  vim.cmd("startinsert!")
end

function M.hide()
  for _, win in ipairs({ M.input_winid, M.staged_winid, M.winid }) do
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  M.winid = nil
  M.staged_winid = nil
  M.input_winid = nil
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
  if M.input_bufnr and vim.api.nvim_buf_is_valid(M.input_bufnr) then
    vim.api.nvim_buf_set_lines(M.input_bufnr, 0, -1, false, { "" })
    set_input_hint()
  end
  M.render()
  notify("aporia: session reset")
end

function M.submit()
  if M.busy then
    return notify("aporia: waiting for the tutor", vim.log.levels.WARN)
  end
  if not (M.input_bufnr and vim.api.nvim_buf_is_valid(M.input_bufnr)) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(M.input_bufnr, 0, -1, false)
  local text = vim.trim(table.concat(lines, "\n"))
  if text == "" then
    return
  end
  local block = require("aporia.context").consume()
  if block ~= "" then
    text = text .. "\n\n" .. block
  end
  table.insert(M.messages, { role = "user", content = text, time = os.date("%H:%M") })
  vim.api.nvim_buf_set_lines(M.input_bufnr, 0, -1, false, { "" })
  set_input_hint()
  M._request()
end

function M._request(opts)
  opts = opts or {}
  M.busy = true
  table.insert(M.messages, { role = "assistant", content = GENERATING, time = os.date("%H:%M") })
  M.render()
  local prompts = require("aporia.prompts")
  local msgs = { { role = "system", content = prompts.system_prompt } }
  vim.list_extend(msgs, M.messages)
  require("aporia.http").request(msgs, function(err, content)
    M.busy = false
    if err then
      M.messages[#M.messages] = { role = "assistant", content = "ERROR: " .. err, time = os.date("%H:%M") }
      M.render()
      return notify(err, vim.log.levels.ERROR)
    end
    M.messages[#M.messages] = { role = "assistant", content = content, time = os.date("%H:%M") }
    M.render()
    require("aporia.fetch").process(content)
    if M.input_winid and vim.api.nvim_win_is_valid(M.input_winid) then
      vim.api.nvim_set_current_win(M.input_winid)
      vim.cmd("startinsert!")
    end
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

local augroup = vim.api.nvim_create_augroup("aporia_chat", { clear = true })
vim.api.nvim_create_autocmd("VimResized", {
  group = augroup,
  callback = function()
    M.render()
  end,
})

return M
