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

function M.new_id()
  return os.date("%Y%m%d-%H%M%S")
end

local function session_dir(mode, root)
  local dir = M.dir(root)
  return dir and vim.fs.joinpath(dir, "sessions", mode)
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

-- newest session for mode: { id, messages } or nil
function M.load_latest(mode, root)
  root = root or M.root()
  if not root then
    return nil
  end
  local dir = vim.fs.joinpath(root, opts().dir, "sessions", mode)
  local names = {}
  for name, kind in vim.fs.dir(dir) do
    if kind == "file" and name:match("%.json$") then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  for i = #names, 1, -1 do
    local f = io.open(vim.fs.joinpath(dir, names[i]), "r")
    if f then
      local ok, doc = pcall(vim.json.decode, f:read("*a"), { luanil = { object = true, array = true } })
      f:close()
      if ok and type(doc) == "table" and type(doc.messages) == "table" then
        return { id = doc.id or names[i]:gsub("%.json$", ""), messages = doc.messages }
      end
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
