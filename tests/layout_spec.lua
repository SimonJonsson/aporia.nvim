local c = require("aporia.chat")
local ctx = require("aporia.context")

local function geom(w)
  local cfg = vim.api.nvim_win_get_config(w)
  local row = type(cfg.row) == "table" and cfg.row[false] or cfg.row
  local col = type(cfg.col) == "table" and cfg.col[false] or cfg.col
  return { row = row, col = col, width = cfg.width, height = cfg.height }
end

local function usable()
  local g = c.geometry()
  return g.usable
end

describe("aporia sidebar layout", function()
  before_each(function()
    ctx.clear()
    c.hide()
  end)

  after_each(function()
    ctx.clear()
    c.hide()
  end)

  it("stacks chat and input in the same column with no overlap", function()
    c.open()
    local chat, input = geom(c.winid), geom(c.input_winid)
    assert.equals(chat.col, input.col)
    assert.equals(chat.width, input.width)
    assert.is_true(input.row >= chat.row + chat.height + 2)
  end)

  it("fits the stack inside the usable grid with no staged box", function()
    c.open()
    local input = geom(c.input_winid)
    assert.is_true(input.row + input.height + 2 <= usable())
    assert.is_nil(c.staged_winid)
  end)

  it("shows the staged box only when something is staged", function()
    c.open()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c" })
    vim.api.nvim_win_set_buf(0, buf)
    ctx.stage_buffer()
    assert.is_not_nil(c.staged_winid)
    ctx.clear()
    c.render()
    assert.is_nil(c.staged_winid)
  end)

  it("sizes the staged box exactly to its content", function()
    c.open()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b" })
    vim.api.nvim_win_set_buf(0, buf)
    ctx.stage_buffer()
    local staged = geom(c.staged_winid)
    local lines = vim.api.nvim_buf_line_count(c.staged_bufnr)
    assert.equals(lines, staged.height)
  end)

  it("pushes the input box below the staged box and keeps everything in the grid", function()
    c.open()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c" })
    vim.api.nvim_win_set_buf(0, buf)
    ctx.stage_buffer()
    local chat, staged, input = geom(c.winid), geom(c.staged_winid), geom(c.input_winid)
    assert.equals(staged.col, chat.col)
    assert.equals(input.col, chat.col)
    assert.is_true(staged.row >= chat.row + chat.height + 2)
    assert.is_true(input.row >= staged.row + staged.height + 2)
    assert.is_true(input.row + input.height + 2 <= usable())
  end)

  it("fills the chat box exactly, no dead rows", function()
    c.open()
    local chat = geom(c.winid)
    assert.equals(chat.height - 1, vim.api.nvim_buf_line_count(c.bufnr))
  end)

  it("pins the title in the chat winbar, hints in the input", function()
    c.open()
    assert.is_truthy(vim.wo[c.winid].winbar:find("✦ aporia"))
    assert.equals("", vim.wo[c.input_winid].winbar or "")
    assert.is_true(vim.api.nvim_buf_line_count(c.bufnr) <= vim.api.nvim_win_get_height(c.winid))
  end)

  it("lists short refs in the staged box", function()
    c.open()
    vim.cmd("new /tmp/aporia_test/demo.lua")
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c", "d" })
    vim.fn.setpos("'<", { buf, 2, 1, 0 })
    vim.fn.setpos("'>", { buf, 2, 1, 0 })
    ctx.stage_selection()
    local lines = vim.api.nvim_buf_get_lines(c.staged_bufnr, 0, -1, false)
    assert.is_truthy(lines[1]:find("staged"))
    assert.equals("/tmp/aporia_test/demo.lua 2-2", lines[3]:gsub("^%s+", ""))
    vim.cmd("close")
  end)

  it("hops C-k/C-j across chat, staged and input", function()    c.open()
    vim.cmd("new /tmp/aporia_test/demo.lua")
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c", "d" })
    vim.api.nvim_set_current_win(c.input_winid)
    ctx.stage_buffer()
    c.render()
    assert.is_truthy(c.staged_winid and vim.api.nvim_win_is_valid(c.staged_winid))

    local function hop(key)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "mx", false)
    end

    hop("<C-k>")
    assert.equals(c.staged_winid, vim.api.nvim_get_current_win())
    hop("<C-k>")
    assert.equals(c.winid, vim.api.nvim_get_current_win())
    hop("<C-j>")
    assert.equals(c.staged_winid, vim.api.nvim_get_current_win())
    hop("<C-j>")
    assert.equals(c.input_winid, vim.api.nvim_get_current_win())
    hop("<C-k>")
    assert.equals(c.staged_winid, vim.api.nvim_get_current_win())
    vim.cmd("close")
  end)

  it("shows the question verbatim with staged context collapsed, za expands", function()
    c.open()
    table.insert(c.messages, {
      role = "user",
      question = "why does this leak?",
      context = "```lua\nlocal x = 1\n```",
      time = "00:00",
    })
    c.render()
    local lines = vim.api.nvim_buf_get_lines(c.bufnr, 0, -1, false)
    local collapsed = nil
    for i, l in ipairs(lines) do
      if l:find("▸ staged context", 1, true) then
        collapsed = i
      end
    end
    assert.is_truthy(collapsed, "collapsed context line missing")
    for _, l in ipairs(lines) do
      assert.falsy(l:find("local x = 1", 1, true))
    end

    vim.api.nvim_set_current_win(c.winid)
    vim.api.nvim_win_set_cursor(c.winid, { collapsed, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("za", true, false, true), "mx", false)
    lines = vim.api.nvim_buf_get_lines(c.bufnr, 0, -1, false)
    local saw_block, saw_marker = false, false
    for _, l in ipairs(lines) do
      if l:find("local x = 1", 1, true) then
        saw_block = true
      end
      if l:find("▾ staged context", 1, true) then
        saw_marker = true
      end
    end
    assert.is_truthy(saw_block, "expanded context missing code block")
    assert.is_truthy(saw_marker, "expanded marker missing")
  end)

  it("folds the full prompt for trap messages and the system prompt for every turn", function()
    c.open()
    table.insert(c.messages, {
      role = "user",
      question = "what I have done so far",
      full = "Here is what I have done so far to debug this:\nwhat I have done so far\n\nCode: ```lua\nx = 1\n```",
      system = "You are a programming tutor.",
      time = "00:00",
    })
    table.insert(c.messages, {
      role = "user",
      question = "plain question",
      full = "plain question",
      system = "You are a programming tutor.",
      time = "00:01",
    })
    c.render()
    local text = table.concat(vim.api.nvim_buf_get_lines(c.bufnr, 0, -1, false), "\n")
    assert.is_truthy(text:find("▸ full prompt", 1, true), "trap full-prompt fold missing")
    assert.falsy(text:find("▸ staged context", 1, true), "trap should not duplicate a staged-context fold")
    assert.equals(2, select(2, text:gsub("▸ system prompt", "")), "system prompt fold per user turn")
    assert.falsy(text:find("You are a programming tutor", 1, true))
  end)
end)
