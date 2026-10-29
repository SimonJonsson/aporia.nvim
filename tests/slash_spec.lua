local c = require("aporia.chat")
local http = require("aporia.http")

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

-- TextChangedI fires only once typeahead is empty, i.e. when a human pauses;
-- feedkeys queues everything at once, so P marks where that pause would be
local P = "<Cmd>doautocmd TextChangedI<CR>"

local function input_line()
  return vim.api.nvim_buf_get_lines(c.input_bufnr, 0, -1, false)[1]
end

describe("aporia slash commands", function()
  local real_request = http.request
  local menu

  before_each(function()
    c.sessions = { assist = {}, teach = {} }
    c.set_mode("assist")
    c.busy = false
    c.open()
    vim.cmd("stopinsert")
    vim.api.nvim_set_current_win(c.input_winid)
    vim.api.nvim_buf_set_lines(c.input_bufnr, 0, -1, false, { "" })
    menu = {}
    -- <F3> snapshots the popup menu from inside insert mode
    vim.keymap.set("i", "<F3>", function()
      local info = vim.fn.complete_info({ "pum_visible", "selected", "items" })
      menu[#menu + 1] = {
        visible = info.pum_visible == 1,
        selected = info.selected,
        count = #info.items,
        line = vim.api.nvim_get_current_line(),
      }
    end, { buffer = c.input_bufnr })
  end)

  after_each(function()
    http.request = real_request
    c.hide()
    c.sessions = { assist = {}, teach = {} }
    c.set_mode("assist")
  end)

  it("opens the menu on / with every command", function()
    feed("i/" .. P .. "<F3><Esc>")
    assert.is_true(menu[1].visible)
    assert.equals(0, menu[1].selected)
    assert.equals(#require("aporia.slash").commands, menu[1].count)
  end)

  it("narrows as you type and accepts with <C-y> only", function()
    feed("i/" .. P .. "t" .. P .. "e" .. P .. "<F3><C-y>" .. P .. "<F3><Esc>")
    assert.is_true(menu[1].visible)
    assert.equals("/teach", menu[2].line)
    assert.is_false(menu[2].visible, "menu reopened after accepting")
  end)

  it("matches descriptions, not just names", function()
    local typed = "i/"
    for ch in ("switch"):gmatch(".") do
      typed = typed .. P .. ch
    end
    feed(typed .. P .. "<F3><C-y><F3><Esc>")
    assert.is_true(menu[1].visible)
    assert.equals(2, menu[1].count)
    assert.equals("/assist", menu[2].line)
  end)

  it("closes the menu when nothing matches instead of listing everything", function()
    feed("i/" .. P .. "z" .. P .. "q" .. P .. "<F3><Esc>")
    assert.is_false(menu[1].visible)
  end)

  it("ranks name matches above description matches", function()
    local names = vim.tbl_map(function(i)
      return i.word
    end, require("aporia.slash").items("as"))
    assert.equals("/assist", names[1])
  end)

  it("moves through the list with <C-n> and <C-p>", function()
    feed("i/" .. P .. "<C-n>" .. P .. "<F3><C-n>" .. P .. "<F3><C-p>" .. P .. "<F3><Esc>")
    assert.equals(1, menu[1].selected)
    assert.equals(2, menu[2].selected)
    assert.equals(1, menu[3].selected)
  end)

  it("<CR> sends what was typed instead of accepting the suggestion", function()
    feed("i/" .. P .. "te" .. P .. "<CR><Esc>")
    assert.equals("/te", input_line())
    assert.equals("assist", c.mode)
  end)

  it("/new starts a fresh conversation in the current mode", function()
    table.insert(c.messages, { role = "user", question = "old", parts = { { text = "old" } }, time = "" })
    c.session_ids.assist = "20260101-000000"
    feed("i/new<CR><Esc>")
    assert.equals(0, #c.messages)
    assert.is_nil(c.session_ids.assist)
    assert.equals("", input_line())
  end)

  it("/teach switches mode", function()
    feed("i/teach<CR><Esc>")
    assert.equals("teach", c.mode)
  end)

  it("// sends a literal slash message", function()
    local sent
    http.request = function(msgs, cb)
      sent = msgs[#msgs].content
      cb(nil, "ok")
    end
    feed("i//usr/bin<CR><Esc>")
    assert.equals("/usr/bin", sent)
  end)
end)
