local M = {
  bufnr = nil,
  winid = nil,
  input_bufnr = nil,
  input_winid = nil,
  -- empty right-hand split the floats sit on, so other windows make room
  spacer_bufnr = nil,
  spacer_winid = nil,
  staged_bufnr = nil,
  staged_winid = nil,
  -- one conversation per mode; messages points at the active one
  sessions = { assist = {}, teach = {} },
  -- on-disk session id per mode; nil until the first message is saved
  session_ids = {},
  messages = nil,
  busy = false,
  mode = "assist",
}
M.messages = M.sessions.assist

local loaded_root

-- load the newest saved session per mode when entering a project; without a
-- project root the in-memory conversations are left alone
local function ensure_loaded()
  local store = require("aporia.store")
  local root = store.root()
  if not root or root == loaded_root then
    return
  end
  loaded_root = root
  for _, mode in ipairs({ "assist", "teach" }) do
    local latest = store.load_latest(mode, root)
    M.sessions[mode] = latest and latest.messages or {}
    M.session_ids[mode] = latest and latest.id or nil
  end
  M.messages = M.sessions[M.mode]
end

local GENERATING = "Generating response…"
local ICONS = { user = "❯", aporia = "◆", staged = "◇" }
local INPUT_HEIGHT = 6
local STAGED_MAX_LINES = 8
local NS = vim.api.nvim_create_namespace("aporia")
local NS_INPUT = vim.api.nvim_create_namespace("aporia_input")

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "aporia" })
end

local function set_highlights()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local code
  if normal and normal.bg then
    local function dim(c)
      return math.floor(c * 0.85)
    end
    code = {
      bg = bit.bor(
        bit.lshift(dim(bit.band(bit.rshift(normal.bg, 16), 0xff)), 16),
        bit.bor(
          bit.lshift(dim(bit.band(bit.rshift(normal.bg, 8), 0xff)), 8),
          dim(bit.band(normal.bg, 0xff))
        )
      ),
    }
  else
    code = { link = "CursorColumn" }
  end
  local groups = {
    AporiaUser = { link = "Question" },
    AporiaReply = { link = "Special" },
    AporiaStaged = { link = "Comment" },
    AporiaHint = { link = "Comment" },
    AporiaAccent = { link = "Keyword" },
    AporiaInputTitle = { link = "Title" },
    AporiaBorder = { link = M.mode == "teach" and "AporiaBorderTeach" or "AporiaBorderAssist" },
    AporiaCode = code,
  }
  for name, def in pairs(groups) do
    vim.api.nvim_set_hl(0, name, def)
  end
  -- default = true so colorschemes and users can override the mode colours
  vim.api.nvim_set_hl(0, "AporiaBorderAssist", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "AporiaBorderTeach", { link = "DiagnosticWarn", default = true })
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

local function spacer_open()
  return M.spacer_winid and vim.api.nvim_win_is_valid(M.spacer_winid)
end

-- an API split does not trigger 'equalalways' the way :vsplit does, so the
-- column would come entirely out of its neighbour; rebalance widths only
local function equalize_widths()
  if not vim.o.equalalways then
    return
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      vim.api.nvim_win_call(win, function()
        -- :horizontal limits CTRL-W = to widths; heights stay as they are
        vim.cmd("horizontal wincmd =")
      end)
      return
    end
  end
end

-- reserve the sidebar column with a real split and place the floats on it
local function reserve_column(g)
  local want = g.width + 2
  if spacer_open() then
    if vim.api.nvim_win_get_width(M.spacer_winid) ~= want then
      vim.api.nvim_win_set_width(M.spacer_winid, want)
    end
  else
    if not (M.spacer_bufnr and vim.api.nvim_buf_is_valid(M.spacer_bufnr)) then
      M.spacer_bufnr = vim.api.nvim_create_buf(false, true)
      vim.bo[M.spacer_bufnr].buftype = "nofile"
      vim.bo[M.spacer_bufnr].filetype = "aporia_spacer"
    end
    M.spacer_winid = vim.api.nvim_open_win(M.spacer_bufnr, false, {
      split = "right",
      win = -1,
      width = want,
      style = "minimal",
    })
    local wo = vim.wo[M.spacer_winid]
    wo.winfixwidth = true
    wo.winfixbuf = true
    wo.winbar = ""
    wo.statuscolumn = ""
    wo.fillchars = "eob: "
    equalize_widths()
  end
  g.col = vim.api.nvim_win_get_position(M.spacer_winid)[2]
  g.width = math.max(vim.api.nvim_win_get_width(M.spacer_winid) - 2, 10)
  return g
end

local function layout(blocks, header_count)
  local g = reserve_column(geometry())
  local staged_text_h = 0
  local staged_h = 0
  if blocks > 0 then
    staged_text_h = math.min(header_count + 2, STAGED_MAX_LINES)
    staged_h = staged_text_h
  end
  local staged_visual = staged_h > 0 and (staged_h + 2) or 0
  local chat_h = math.max(g.usable - staged_visual - INPUT_HEIGHT - 4, 4)

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
      row = g.row + chat_h + 2 + staged_visual,
      col = g.col,
      width = g.width,
      height = INPUT_HEIGHT,
    })
  else
    open_input_float(g, g.row + chat_h + 2 + staged_visual)
  end
end

M.geometry = geometry

local function scroll_bottom()
  if not (M.winid and vim.api.nvim_win_is_valid(M.winid)) then
    return
  end
  pcall(vim.api.nvim_win_set_cursor, M.winid, { vim.api.nvim_buf_line_count(M.bufnr), 0 })
  pcall(vim.fn.win_execute, M.winid, "setlocal scrolloff=0 | normal! Gzb")
end

local function render_chat()
  local out = {}
  local hls = {}
  M._ctx_line_map = {}

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

  for i, m in ipairs(M.messages) do
    out[#out + 1] = ""
    if m.role == "user" then
      add(ICONS.user .. " You · " .. (m.time or ""), "AporiaUser")
      if m.question and m.question ~= "" then
        vim.list_extend(out, vim.split(m.question, "\n"))
      end
      local function add_body(body, code_all)
        local start = #out
        vim.list_extend(out, vim.split(body, "\n"))
        if code_all then
          for l = start + 1, #out do
            hls[l] = "AporiaCode"
          end
        else
          local inside = false
          for l = start + 1, #out do
            if out[l]:find("^```") then
              inside = not inside
              hls[l] = "AporiaCode"
            elseif inside then
              hls[l] = "AporiaCode"
            end
          end
        end
      end
      local function fold(kind, label, body, code_all)
        if not body or body == "" then
          return
        end
        if m["expanded_" .. kind] then
          add("▾ " .. label .. " · za to collapse", "AporiaHint")
          M._ctx_line_map[#out] = { i, kind }
          add_body(body, code_all)
        else
          add("▸ " .. label .. " · za to expand", "AporiaHint")
          M._ctx_line_map[#out] = { i, kind }
        end
      end
      if m.parts then
        if m.expanded_full then
          add("▾ full prompt · za to collapse", "AporiaHint")
          M._ctx_line_map[#out] = { i, "full" }
          for pi, part in ipairs(m.parts) do
            if part.text ~= nil then
              add_body(part.text, false)
            else
              local label = part.short or "staged code"
              if part.expanded then
                add("▾ " .. label .. " · za to collapse", "AporiaHint")
                M._ctx_line_map[#out] = { i, "part", pi }
                add_body(part.block, true)
              else
                add("▸ " .. label .. " · za to expand", "AporiaHint")
                M._ctx_line_map[#out] = { i, "part", pi }
              end
            end
          end
        else
          add("▸ full prompt · za to expand", "AporiaHint")
          M._ctx_line_map[#out] = { i, "full" }
        end
      else
        local full_redundant = m.full == nil
          or m.full == m.question
          or (m.context ~= nil and m.full == m.question .. "\n\n" .. m.context)
        if m.full and not full_redundant then
          fold("full", "full prompt", m.full, false)
        end
        if m.context_blocks then
          for j, b in ipairs(m.context_blocks) do
            fold("context" .. j, b.short or b.header or "staged context", b.block, true)
          end
        elseif m.context then
          fold("context", "staged context", m.context, true)
        end
      end
      fold("system", m.mode and ("system prompt · " .. m.mode) or "system prompt", m.system, false)
    else
      add(ICONS.aporia .. " Aporia · " .. (m.time or ""), "AporiaReply")
      vim.list_extend(out, vim.split(m.content or "", "\n"))
    end
  end

  local content_height = M.winid
    and vim.api.nvim_win_is_valid(M.winid)
    and vim.api.nvim_win_get_height(M.winid)
    or 30
  local pad = math.max(0, content_height - #out)
  local offset_map = {}
  for line, idx in pairs(M._ctx_line_map) do
    offset_map[line + pad] = idx
  end
  M._ctx_line_map = offset_map
  local padded = {}
  for _ = 1, pad do
    padded[#padded + 1] = ""
  end
  vim.list_extend(padded, out)

  local was_at_bottom = true
  if M.winid and vim.api.nvim_win_is_valid(M.winid) then
    local info = vim.fn.getwininfo(M.winid)[1]
    if info then
      was_at_bottom = info.topline + info.height >= vim.api.nvim_buf_line_count(M.bufnr) - 1
    end
  end

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

  if M.winid and vim.api.nvim_win_is_valid(M.winid) then
    local info = vim.fn.getwininfo(M.winid)[1]
    local last = vim.api.nvim_buf_line_count(M.bufnr)
    if info then
      if was_at_bottom then
        scroll_bottom()
      elseif last <= info.height then
        pcall(vim.api.nvim_win_set_cursor, M.winid, { 1, 0 })
      end
    end
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
  if not (M.winid and vim.api.nvim_win_is_valid(M.winid)) then
    return
  end
  set_highlights()
  local context = require("aporia.context")
  local blocks, staged_lines = context.summary()
  local headers = context.headers()
  layout(blocks, #headers)
  render_chat()
  render_staged(blocks, staged_lines, headers)
end

local function focus_chat()
  if not (M.winid and vim.api.nvim_win_is_valid(M.winid)) then
    return
  end
  vim.api.nvim_set_current_win(M.winid)
  pcall(vim.api.nvim_win_set_cursor, M.winid, { vim.api.nvim_buf_line_count(M.bufnr), 0 })
end

local function staged_open()
  return M.staged_winid ~= nil and vim.api.nvim_win_is_valid(M.staged_winid)
end

local function persist(mode)
  local store = require("aporia.store")
  local root = store.root()
  local list = M.sessions[mode]
  if not root or #list == 0 then
    return
  end
  M.session_ids[mode] = M.session_ids[mode] or store.new_id()
  local out = {}
  for _, m in ipairs(list) do
    if m.content ~= GENERATING then
      out[#out + 1] = m
    end
  end
  store.save(mode, M.session_ids[mode], out, root)
end

-- start a fresh conversation in the current mode; the old one stays on disk
function M.new_session()
  M.sessions[M.mode] = {}
  M.session_ids[M.mode] = nil
  M.messages = M.sessions[M.mode]
  M.render()
  notify("aporia: new " .. M.mode .. " conversation")
end

-- delete every saved session in this project and start both modes fresh
function M.delete_all_sessions()
  local store = require("aporia.store")
  local root = store.root()
  if not root then
    return notify("aporia: no project root, nothing is saved", vim.log.levels.WARN)
  end
  local n = store.count(root)
  local prompt = ("Delete all %d saved aporia session%s in %s?"):format(n, n == 1 and "" or "s", root)
  if vim.fn.confirm(prompt, "&Yes\n&No", 2) ~= 1 then
    return
  end
  store.delete_all(root)
  M.sessions = { assist = {}, teach = {} }
  M.session_ids = {}
  M.messages = M.sessions[M.mode]
  M.render()
  notify(("aporia: deleted %d session%s"):format(n, n == 1 and "" or "s"))
end

local function clear_chat()
  if #M.messages == 0 then
    return
  end
  if vim.fn.confirm("Clear the conversation? (staged context is kept)", "&Yes\n&No", 2) ~= 1 then
    return
  end
  M.new_session()
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
  vim.keymap.set("n", "x", clear_chat, { buffer = M.bufnr, silent = true })
  vim.keymap.set("n", "za", function()
    local line = vim.fn.line(".")
    local ref = M._ctx_line_map and M._ctx_line_map[line]
    local m = ref and M.messages[ref[1]]
    if not m then
      return
    end
    if ref[2] == "part" then
      local part = m.parts[ref[3]]
      if part then
        part.expanded = not part.expanded
      end
    else
      m["expanded_" .. ref[2]] = not m["expanded_" .. ref[2]]
    end
    M.render()
    pcall(vim.api.nvim_win_set_cursor, M.winid, { line, 0 })
    local info = vim.fn.getwininfo(M.winid)[1]
    local last = vim.api.nvim_buf_line_count(M.bufnr)
    if info and info.topline + info.height - 1 > last then
      scroll_bottom()
    end
  end, { buffer = M.bufnr, silent = true })
  vim.keymap.set("n", "<C-j>", function()
    if staged_open() then
      vim.api.nvim_set_current_win(M.staged_winid)
    else
      M.focus()
    end
  end, { buffer = M.bufnr, silent = true })
  pcall(vim.treesitter.start, M.bufnr, "markdown")
end

local function set_input_chrome()
  if not (M.input_bufnr and vim.api.nvim_buf_is_valid(M.input_bufnr)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(M.input_bufnr, NS_INPUT, 0, -1)
  local last = vim.api.nvim_buf_line_count(M.input_bufnr) - 1
  vim.api.nvim_buf_set_extmark(M.input_bufnr, NS_INPUT, last, 0, {
    virt_lines = {
      {
        { " " .. M.mode, "AporiaAccent" },
        { " · <CR> send · <C-j> newline · <C-k> up · x clear · q hide", "AporiaHint" },
      },
    },
  })
end

local function create_input_buffer()
  M.input_bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[M.input_bufnr].buftype = "nofile"
  vim.bo[M.input_bufnr].swapfile = false
  vim.bo[M.input_bufnr].textwidth = 0
  vim.bo[M.input_bufnr].formatoptions = ""
  vim.b[M.input_bufnr].completion = false
  set_input_chrome()
  local opts = { buffer = M.input_bufnr, silent = true }
  require("aporia.slash").attach(M.input_bufnr)
  vim.keymap.set("n", "<CR>", function()
    M.submit()
  end, opts)
  -- <CR> sends what was typed; with the slash menu open it dismisses it first
  -- (only <C-y> accepts a suggestion)
  vim.keymap.set("i", "<CR>", function()
    return (vim.fn.pumvisible() == 1 and "<C-e>" or "") .. "<Cmd>lua require('aporia.chat').submit()<CR>"
  end, vim.tbl_extend("force", opts, { expr = true }))
  vim.keymap.set("i", "<C-j>", "<CR>", opts)
  vim.keymap.set({ "n", "i" }, "<C-k>", function()
    vim.cmd("stopinsert")
    if staged_open() then
      vim.api.nvim_set_current_win(M.staged_winid)
    else
      focus_chat()
    end
  end, opts)
  vim.keymap.set("n", "q", function()
    M.hide()
  end, opts)
  vim.keymap.set("n", "x", clear_chat, opts)
end

function create_staged_buffer()
  M.staged_bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[M.staged_bufnr].buftype = "nofile"
  vim.bo[M.staged_bufnr].swapfile = false
  vim.keymap.set("n", "d", function()
    require("aporia.context").unstage(vim.fn.line(".") - 1)
    M.render()
  end, { buffer = M.staged_bufnr, silent = true })
  vim.keymap.set("n", "<C-k>", function()
    focus_chat()
  end, { buffer = M.staged_bufnr, silent = true })
  vim.keymap.set("n", "<C-j>", function()
    M.focus()
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
  wo.winhighlight = "FloatBorder:AporiaBorder,Normal:NormalFloat"
end

function M.focus()
  if not (M.winid and vim.api.nvim_win_is_valid(M.winid)) then
    return false
  end
  vim.api.nvim_set_current_win(M.input_winid)
  vim.cmd("startinsert!")
  return true
end

local nav_ours_desc = "Aporia: back to chat (else original <C-l>)"
local nav_key = "<C-l>"
local nav_prev = nil
local nav_group = nil

local function mapping_is_ours(m)
  return m and m.desc == nav_ours_desc
end

local function ensure_nav()
  local cur = vim.fn.maparg(nav_key, "n", false, true)
  if mapping_is_ours(cur) then
    return
  end
  if cur and (cur.callback or (cur.rhs and cur.rhs ~= "")) then
    nav_prev = cur
  else
    nav_prev = nil
  end
  if not nav_group then
    nav_group = vim.api.nvim_create_augroup("aporia_nav", { clear = true })
  end
  vim.keymap.set("n", nav_key, function()
    if
      M.winid
      and vim.api.nvim_win_is_valid(M.winid)
      and vim.api.nvim_win_get_config(0).relative == ""
    then
      M.focus()
    else
      if nav_prev and nav_prev.callback then
        pcall(nav_prev.callback)
      elseif nav_prev and nav_prev.rhs and nav_prev.rhs ~= "" then
        local keys = vim.api.nvim_replace_termcodes(nav_prev.rhs, true, false, true)
        vim.api.nvim_feedkeys(keys, "m", false)
      else
        vim.cmd("wincmd l")
      end
    end
  end, { desc = nav_ours_desc })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = nav_group,
    callback = ensure_nav,
  })
end

function M.open()
  ensure_loaded()
  ensure_nav()
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
  local context = require("aporia.context")
  local blocks, staged_lines = context.summary()
  local headers = context.headers()
  layout(blocks, #headers)
  render_chat()
  render_staged(blocks, staged_lines, headers)
  vim.api.nvim_set_current_win(M.input_winid)
  vim.cmd("startinsert!")
end

local function is_our_float(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return false
  end
  if vim.api.nvim_win_get_config(win).relative == "" then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  return buf == M.bufnr or buf == M.input_bufnr or buf == M.staged_bufnr
end

function M.hide()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_our_float(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  -- forget the spacer before closing it, so our own WinClosed handler
  -- does not schedule a second hide that would take down the next open
  local spacer = M.spacer_winid
  M.spacer_winid = nil
  if spacer and vim.api.nvim_win_is_valid(spacer) then
    -- fails only when the spacer is the last window; QuitPre prevents that
    if pcall(vim.api.nvim_win_close, spacer, true) then
      equalize_widths()
    end
  end
  M.winid = nil
  M.staged_winid = nil
  M.input_winid = nil
end

function M.set_mode(mode)
  M.mode = mode
  M.messages = M.sessions[mode]
  set_input_chrome()
  M.render()
end

-- toggle(mode): hide if already open in that mode, otherwise switch to it
function M.toggle(mode)
  local is_open = M.winid and vim.api.nvim_win_is_valid(M.winid)
  if is_open and (not mode or mode == M.mode) then
    return M.hide()
  end
  if mode then
    M.set_mode(mode)
  end
  M.open()
end

function M.reset()
  M.sessions = { assist = {}, teach = {} }
  M.session_ids = {}
  M.messages = M.sessions[M.mode]
  require("aporia.context").clear()
  if M.input_bufnr and vim.api.nvim_buf_is_valid(M.input_bufnr) then
    vim.api.nvim_buf_set_lines(M.input_bufnr, 0, -1, false, { "" })
    set_input_chrome()
  end
  M.render()
  notify("aporia: session reset")
end

function M.submit()
  if not (M.input_bufnr and vim.api.nvim_buf_is_valid(M.input_bufnr)) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(M.input_bufnr, 0, -1, false)
  local text = vim.trim(table.concat(lines, "\n"))
  if text == "" then
    return
  end
  -- commands run even while a reply is pending
  local ran = require("aporia.slash").dispatch(text, M)
  if ran ~= nil then
    if ran then
      vim.api.nvim_buf_set_lines(M.input_bufnr, 0, -1, false, { "" })
      set_input_chrome()
    end
    return
  end
  if M.busy then
    return notify("aporia: waiting for a reply", vim.log.levels.WARN)
  end
  if text:sub(1, 2) == "//" then
    text = text:sub(2)
  end
  local block_list = require("aporia.context").consume_blocks()
  local parts = { { text = text } }
  for _, b in ipairs(block_list) do
    parts[#parts + 1] = { sep = "\n\n", short = b.short or b.header, block = b.block }
  end
  table.insert(M.messages, {
    role = "user",
    question = text,
    parts = parts,
    mode = M.mode,
    system = require("aporia.prompts").system(M.mode),
    time = os.date("%H:%M"),
  })
  vim.api.nvim_buf_set_lines(M.input_bufnr, 0, -1, false, { "" })
  set_input_chrome()
  persist(M.mode)
  M._request()
end

local function api_messages()
  local out = { { role = "system", content = require("aporia.prompts").system(M.mode) } }
  for _, m in ipairs(M.messages) do
    if m.role == "user" then
      local content
      if m.parts then
        local pieces = {}
        for _, part in ipairs(m.parts) do
          pieces[#pieces + 1] = part.text or (part.sep or "") .. part.block
        end
        content = table.concat(pieces, "")
      else
        content = m.full
        if not content then
          content = m.question or ""
          if m.context and m.context ~= "" then
            content = content .. "\n\n" .. m.context
          end
        end
      end
      out[#out + 1] = { role = "user", content = content }
    elseif m.content ~= GENERATING and not m.error then
      out[#out + 1] = { role = m.role, content = m.content }
    end
  end
  return out
end

function M._request(opts)
  opts = opts or {}
  M.busy = true
  -- the reply belongs to this conversation even if the mode switches meanwhile
  local list, mode = M.messages, M.mode
  table.insert(list, { role = "assistant", content = GENERATING, time = os.date("%H:%M") })
  local slot = #list
  M.render()
  local msgs = api_messages()
  require("aporia.http").request(msgs, function(err, content)
    M.busy = false
    if err then
      list[slot] = { role = "assistant", content = "ERROR: " .. err, error = true, time = os.date("%H:%M") }
      M.render()
      return notify(err, vim.log.levels.ERROR)
    end
    list[slot] = { role = "assistant", content = content, time = os.date("%H:%M") }
    if list == M.sessions[mode] then
      persist(mode)
    end
    M.render()
    require("aporia.fetch").process(content)
    if M.input_winid and vim.api.nvim_win_is_valid(M.input_winid) and M.winid and vim.api.nvim_win_is_valid(M.winid) then
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
  ensure_loaded()
  M.set_mode("teach")
  local input = t.ask and vim.trim(vim.fn.input(t.ask .. ": ")) or ""
  local block = require("aporia.context").capture_current()
  local function fill(s)
    return (s:gsub("{input}", function()
      return input
    end))
  end
  local parts
  local pre, post = t.template:match("^(.-){selection}(.*)$")
  if pre then
    parts = {
      { text = fill(pre) },
      { sep = "", short = block.short or block.header, block = block.block },
      { text = fill(post) },
    }
  else
    parts = { { text = fill(t.template:gsub("{selection}", function()
      return block.block
    end)) } }
  end
  M.open()
  table.insert(M.messages, {
    role = "user",
    question = input,
    parts = parts,
    mode = M.mode,
    system = require("aporia.prompts").system(M.mode),
    time = os.date("%H:%M"),
  })
  persist(M.mode)
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
    if M.winid and vim.api.nvim_win_is_valid(M.winid) then
      M.render()
    end
  end,
})
-- the spacer is never a place to be: landing on it (<C-w>l etc.) means "go to aporia"
vim.api.nvim_create_autocmd("WinEnter", {
  group = augroup,
  callback = function()
    if spacer_open() and vim.api.nvim_get_current_win() == M.spacer_winid then
      vim.schedule(M.focus)
    end
  end,
})
-- :only or <C-w>o took the spacer with it: take the floats down too
vim.api.nvim_create_autocmd("WinClosed", {
  group = augroup,
  callback = function(ev)
    if M.spacer_winid and tonumber(ev.match) == M.spacer_winid then
      vim.schedule(M.hide)
    end
  end,
})
-- quitting the last real window must quit nvim, not strand the sidebar
vim.api.nvim_create_autocmd("QuitPre", {
  group = augroup,
  callback = function()
    if not spacer_open() then
      return
    end
    local cur = vim.api.nvim_get_current_win()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if win ~= cur and win ~= M.spacer_winid and vim.api.nvim_win_get_config(win).relative == "" then
        return
      end
    end
    M.hide()
  end,
})

return M
