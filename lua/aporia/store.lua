-- Project cache in <root>/.aporia/. The directory ignores itself via its own
-- .gitignore, so no repository's ignore file has to be touched.
local M = {}

local function opts()
  return require("aporia.config").options.persist
end

function M.root()
  if not opts().enabled then
    return nil
  end
  return vim.fs.root(vim.fn.getcwd(), opts().markers)
end

local function write(path, text)
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then
    return false
  end
  f:write(text)
  f:close()
  return vim.uv.fs_rename(tmp, path) ~= nil
end

-- <root>/.aporia, created on first use; nil when there is no project root
function M.dir(root)
  root = root or M.root()
  if not root then
    return nil
  end
  local dir = vim.fs.joinpath(root, opts().dir)
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  local ignore = vim.fs.joinpath(dir, ".gitignore")
  if not vim.uv.fs_stat(ignore) then
    write(ignore, "*\n")
  end
  return dir
end

local function session_dir(mode, root)
  local dir = M.dir(root)
  return dir and vim.fs.joinpath(dir, "sessions", mode)
end

local function session_path(mode, id, root)
  root = root or M.root()
  return root and vim.fs.joinpath(root, opts().dir, "sessions", mode, id .. ".json")
end

-- a timestamp id, made unique within the mode's directory
function M.new_id(mode, root)
  local base = os.date("%Y%m%d-%H%M%S")
  local id, n = base, 1
  while mode and root and vim.uv.fs_stat(session_path(mode, id, root)) do
    n = n + 1
    id = base .. "-" .. n
  end
  return id
end

-- What the file looks like on disk right now; nil when it does not exist.
-- An instance compares this with what it saw at its last load or save to
-- notice another Neovim writing the same conversation.
function M.stamp(mode, id, root)
  local path = session_path(mode, id, root)
  local stat = path and vim.uv.fs_stat(path)
  if not stat then
    return nil
  end
  return ("%d.%d:%d"):format(stat.mtime.sec, stat.mtime.nsec, stat.size)
end

function M.save(mode, id, messages, root)
  local dir = session_dir(mode, root)
  if not dir then
    return false
  end
  vim.fn.mkdir(dir, "p")
  local doc = { version = 1, mode = mode, id = id, messages = messages }
  return write(vim.fs.joinpath(dir, id .. ".json"), vim.json.encode(doc))
end

local function read(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local ok, doc = pcall(vim.json.decode, f:read("*a"), { luanil = { object = true, array = true } })
  f:close()
  if ok and type(doc) == "table" and type(doc.messages) == "table" then
    return doc
  end
  return nil
end

-- one session: { id, messages } or nil
function M.load(mode, id, root)
  local path = session_path(mode, id, root)
  local doc = path and read(path)
  return doc and { id = id, messages = doc.messages }
end

-- the mode's sessions, newest first: { id, turns, first }, where first is
-- the opening question
function M.list(mode, root)
  root = root or M.root()
  if not root then
    return {}
  end
  local dir = vim.fs.joinpath(root, opts().dir, "sessions", mode)
  local ids = {}
  for name, kind in vim.fs.dir(dir) do
    if kind == "file" and name:match("%.json$") then
      ids[#ids + 1] = name:gsub("%.json$", "")
    end
  end
  table.sort(ids, function(a, b)
    return a > b
  end)
  local out = {}
  for _, id in ipairs(ids) do
    local doc = read(vim.fs.joinpath(dir, id .. ".json"))
    if doc then
      local turns, first = 0, nil
      for _, m in ipairs(doc.messages) do
        if m.role == "user" then
          turns = turns + 1
          first = first or m.question or (m.parts and m.parts[1] and m.parts[1].text)
        end
      end
      out[#out + 1] = { id = id, turns = turns, first = first or "" }
    end
  end
  return out
end

-- newest session for mode: { id, messages } or nil
function M.load_latest(mode, root)
  for _, s in ipairs(M.list(mode, root)) do
    local loaded = M.load(mode, s.id, root)
    if loaded then
      return loaded
    end
  end
  return nil
end

-- saved session files under root, for confirmation prompts
function M.count(root)
  root = root or M.root()
  if not root then
    return 0
  end
  local n = 0
  local base = vim.fs.joinpath(root, opts().dir, "sessions")
  for name, kind in vim.fs.dir(base, { depth = 2 }) do
    if kind == "file" and name:match("%.json$") then
      n = n + 1
    end
  end
  return n
end

-- delete every saved session in the project; returns how many were removed
function M.delete_all(root)
  root = root or M.root()
  if not root then
    return 0
  end
  local n = M.count(root)
  vim.fn.delete(vim.fs.joinpath(root, opts().dir, "sessions"), "rf")
  return n
end

return M
