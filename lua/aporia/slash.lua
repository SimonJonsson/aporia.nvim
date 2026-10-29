-- Slash commands typed into the chat input. Completion uses the native popup
-- menu, so <C-n>/<C-p> move, <C-y> accepts and <C-e> dismisses, as in blink.
local M = {}

M.commands = {
  {
    name = "new",
    desc = "fresh conversation in this mode",
    run = function(chat)
      chat.new_session()
    end,
  },
  {
    name = "resume",
    desc = "pick a saved conversation of this mode and continue it",
    run = function(chat)
      chat.resume()
    end,
  },
  {
    name = "assist",
    desc = "switch to assist mode",
    run = function(chat)
      chat.set_mode("assist")
    end,
  },
  {
    name = "teach",
    desc = "switch to teach mode",
    run = function(chat)
      chat.set_mode("teach")
    end,
  },
  {
    name = "delete-all-sessions",
    desc = "delete every saved session in this project (asks first)",
    run = function(chat)
      chat.delete_all_sessions()
    end,
  },
  {
    name = "reset",
    desc = "wipe both conversations and staged context",
    run = function(chat)
      chat.reset()
    end,
  },
}

local function find(name)
  for _, cmd in ipairs(M.commands) do
    if cmd.name == name then
      return cmd
    end
  end
end

-- "/name" alone on the first line, cursor at its end
local function typed_name(bufnr)
  if vim.api.nvim_buf_line_count(bufnr) ~= 1 then
    return nil
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
  local name = line:match("^/(%S*)$")
  if name and vim.api.nvim_win_get_cursor(0)[2] == #line then
    return name
  end
end

local function desc_matches(desc, query)
  for word in desc:lower():gmatch("%S+") do
    if word:sub(1, #query) == query then
      return true
    end
  end
  return false
end

-- commands for query: fuzzy matches on the name first, then commands whose
-- description has a word starting with it
function M.items(query)
  query = (query or ""):lower()
  local names = {}
  for _, cmd in ipairs(M.commands) do
    names[#names + 1] = cmd.name
  end
  local ordered = query == "" and names or vim.fn.matchfuzzy(names, query)
  local seen = {}
  for _, name in ipairs(ordered) do
    seen[name] = true
  end
  if query ~= "" then
    for _, cmd in ipairs(M.commands) do
      if not seen[cmd.name] and desc_matches(cmd.desc, query) then
        ordered[#ordered + 1] = cmd.name
      end
    end
  end
  local items = {}
  for _, name in ipairs(ordered) do
    items[#items + 1] = { word = "/" .. name, menu = find(name).desc }
  end
  return items
end

-- (re)fill the menu from what is typed; a complete name needs no menu.
-- Native completion only prefix-filters on its own, so every change
-- recomputes the list here.
function M.trigger(bufnr)
  local name = typed_name(bufnr)
  if vim.fn.pumvisible() == 1 then
    -- <C-n>/<C-p> put the selected word in the line: navigating, not typing
    local info = vim.fn.complete_info({ "selected", "items" })
    local sel = info.items[info.selected + 1]
    if not name or (sel and sel.word == "/" .. name) then
      return
    end
  end
  if not name or find(name) then
    return
  end
  local items = M.items(name)
  if #items > 0 then
    vim.fn.complete(1, items)
  elseif vim.fn.pumvisible() == 1 then
    vim.fn.complete(1, {})
  end
end

-- nil: not a command, send it as a message ("//text" sends "/text")
-- true: command ran; false: unknown command, leave the input for fixing
function M.dispatch(text, chat)
  if text:sub(1, 2) == "//" or text:sub(1, 1) ~= "/" then
    return nil
  end
  local name = text:match("^/(%S+)")
  local cmd = name and find(name)
  if not cmd then
    vim.notify("aporia: unknown command " .. text:match("^%S*") .. " (send //… for a literal slash)", vim.log.levels.WARN)
    return false
  end
  cmd.run(chat)
  return true
end

function M.attach(bufnr)
  pcall(function()
    vim.bo[bufnr].completeopt = "menuone,noinsert"
  end)
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP" }, {
    buffer = bufnr,
    callback = function()
      M.trigger(bufnr)
    end,
  })
  local opts = { buffer = bufnr, expr = true, silent = true }
  local function menu_key(key)
    return function()
      if vim.fn.pumvisible() == 1 then
        return key
      end
      -- menu closed: <C-n>/<C-p> reopen it on a command, otherwise do nothing
      if typed_name(bufnr) then
        return "<Cmd>lua require('aporia.slash').trigger(" .. bufnr .. ")<CR>"
      end
      return ""
    end
  end
  -- buffer-local so a global completion plugin's mappings cannot swallow them
  vim.keymap.set("i", "<C-n>", menu_key("<C-n>"), opts)
  vim.keymap.set("i", "<C-p>", menu_key("<C-p>"), opts)
  vim.keymap.set("i", "<C-y>", function()
    return vim.fn.pumvisible() == 1 and "<C-y>" or ""
  end, opts)
  vim.keymap.set("i", "<C-e>", function()
    return vim.fn.pumvisible() == 1 and "<C-e>" or ""
  end, opts)
end

return M
