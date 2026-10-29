-- Read-only tools the model can call while answering in assist mode.
-- The backend (backend/) runs the loop and asks Neovim to run these, so they
-- see the editor's state: an open buffer is read as it is, unsaved edits
-- included. Everything is confined to the project root, and files git
-- ignores (.env, build output) are refused so they are never sent anywhere.
local M = {}

local MAX_READ_LINES = 400
local MAX_LIST = 400
local MAX_GREP = 80
local MAX_OUTPUT = 40000

local function root()
  return require("aporia.store").root() or vim.fn.getcwd()
end

local function is_git(dir)
  return vim.uv.fs_stat(vim.fs.joinpath(dir, ".git")) ~= nil
end

local function cap(s)
  if #s > MAX_OUTPUT then
    return s:sub(1, MAX_OUTPUT) .. "\n… (output cut at " .. MAX_OUTPUT .. " characters)"
  end
  return s
end

-- a path from the model, as an absolute path inside the root, or nil and why
local function resolve(dir, path)
  path = path or "."
  if path == "" then
    path = "."
  end
  local abs = vim.fs.normalize(path:sub(1, 1) == "/" and path or vim.fs.joinpath(dir, path))
  local real = vim.uv.fs_realpath(abs)
  if not real then
    return nil, "no such file or directory: " .. path
  end
  local real_root = vim.uv.fs_realpath(dir) or dir
  if real ~= real_root and real:sub(1, #real_root + 1) ~= real_root .. "/" then
    return nil, "outside the project: " .. path
  end
  local rel = real == real_root and "." or real:sub(#real_root + 2)
  local first = rel:match("^[^/]+")
  local persist_dir = require("aporia.config").options.persist.dir
  if first == ".git" or first == persist_dir then
    return nil, "not readable: " .. rel
  end
  if rel ~= "." and is_git(real_root) then
    local ignored = vim.system({ "git", "-C", real_root, "check-ignore", "-q", "--", rel }):wait()
    if ignored.code == 0 then
      return nil, "ignored by git, not readable: " .. rel
    end
  end
  return real, rel
end

M.specs = {
  {
    type = "function",
    ["function"] = {
      name = "list_files",
      description = "List the project's files (git-tracked and untracked, ignored files excluded), optionally under a directory.",
      parameters = {
        type = "object",
        properties = {
          path = { type = "string", description = "Directory relative to the project root; default the root." },
        },
      },
    },
  },
  {
    type = "function",
    ["function"] = {
      name = "grep",
      description = "Search file contents with a regular expression (ripgrep syntax). Returns path:line:text matches.",
      parameters = {
        type = "object",
        properties = {
          pattern = { type = "string", description = "Regular expression to search for." },
          path = { type = "string", description = "File or directory to search in; default the whole project." },
        },
        required = { "pattern" },
      },
    },
  },
  {
    type = "function",
    ["function"] = {
      name = "read_file",
      description = ("Read a file with line numbers, at most %d lines per call; ask for a range to read more of a long file."):format(
        MAX_READ_LINES
      ),
      parameters = {
        type = "object",
        properties = {
          path = { type = "string", description = "File path relative to the project root." },
          start_line = { type = "integer", description = "First line, 1-based; default 1." },
          end_line = { type = "integer", description = "Last line, inclusive." },
        },
        required = { "path" },
      },
    },
  },
}

-- what the chat shows for a step, e.g. "read lua/aporia/chat.lua:10-40"
function M.label(name, args)
  args = type(args) == "table" and args or {}
  if name == "read_file" then
    local range = ""
    if args.start_line or args.end_line then
      range = ":" .. (args.start_line or 1) .. "-" .. (args.end_line or "")
    end
    return "read " .. tostring(args.path or "?") .. range
  elseif name == "list_files" then
    return "list files" .. ((args.path and args.path ~= "" and args.path ~= ".") and (" in " .. args.path) or "")
  elseif name == "grep" then
    return "search " .. vim.inspect(tostring(args.pattern or ""))
      .. ((args.path and args.path ~= "") and (" in " .. args.path) or "")
  end
  return name
end

local run = {}

function run.list_files(args, dir)
  local abs, rel = resolve(dir, args.path)
  if not abs then
    return nil, rel
  end
  local files
  if is_git(dir) then
    local res = vim
      .system({ "git", "ls-files", "--cached", "--others", "--exclude-standard", "--", rel }, { cwd = dir, text = true })
      :wait()
    if res.code ~= 0 then
      return nil, vim.trim(res.stderr or "git ls-files failed")
    end
    files = vim.split(vim.trim(res.stdout or ""), "\n", { trimempty = true })
  else
    files = {}
    for name, kind in vim.fs.dir(abs, {
      depth = 8,
      skip = function(d)
        return not d:match("^%.")
      end,
    }) do
      if kind == "file" then
        files[#files + 1] = rel == "." and name or (rel .. "/" .. name)
      end
    end
    table.sort(files)
  end
  local total = #files
  local shown = vim.list_slice(files, 1, MAX_LIST)
  local out = table.concat(shown, "\n")
  if total > MAX_LIST then
    out = out .. ("\n… %d more; list a subdirectory to see them"):format(total - MAX_LIST)
  end
  return out, total .. " files"
end

function run.grep(args, dir)
  if type(args.pattern) ~= "string" or args.pattern == "" then
    return nil, "pattern is required"
  end
  local abs, rel = resolve(dir, args.path)
  if not abs then
    return nil, rel
  end
  local cmd
  if vim.fn.executable("rg") == 1 then
    cmd = { "rg", "--line-number", "--no-heading", "--color=never", "--max-columns=200", "-e", args.pattern, "--", rel }
  elseif is_git(dir) then
    cmd = { "git", "grep", "-n", "--untracked", "-e", args.pattern, "--", rel }
  else
    return nil, "grep needs ripgrep (rg) or a git repository"
  end
  local res = vim.system(cmd, { cwd = dir, text = true }):wait()
  -- rg and git grep both exit 1 for "no matches"
  if res.code == 1 then
    return "no matches", "no matches"
  elseif res.code ~= 0 then
    return nil, vim.trim(res.stderr or "search failed")
  end
  local lines = vim.split(vim.trim(res.stdout or ""), "\n", { trimempty = true })
  local total = #lines
  local out = table.concat(vim.list_slice(lines, 1, MAX_GREP), "\n")
  if total > MAX_GREP then
    out = out .. ("\n… %d more matches; narrow the pattern or the path"):format(total - MAX_GREP)
  end
  return out, total .. (total == 1 and " match" or " matches")
end

function run.read_file(args, dir)
  if type(args.path) ~= "string" or args.path == "" then
    return nil, "path is required"
  end
  local abs, rel = resolve(dir, args.path)
  if not abs then
    return nil, rel
  end
  if vim.fn.isdirectory(abs) == 1 then
    return nil, rel .. " is a directory; use list_files"
  end
  local lines
  local buf = vim.fn.bufnr(abs)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  else
    local ok, read = pcall(vim.fn.readfile, abs)
    if not ok then
      return nil, "cannot read " .. rel
    end
    lines = read
  end
  for i = 1, math.min(#lines, 50) do
    if lines[i]:find("\0", 1, true) then
      return nil, rel .. " is a binary file"
    end
  end
  local total = #lines
  local first = math.max(1, math.floor(tonumber(args.start_line) or 1))
  local last = math.min(total, math.floor(tonumber(args.end_line) or total), first + MAX_READ_LINES - 1)
  if total == 0 then
    return rel .. " is empty", "empty"
  end
  if first > total then
    return nil, ("%s has %d lines"):format(rel, total)
  end
  local out = { ("%s (lines %d-%d of %d)"):format(rel, first, last, total) }
  for i = first, last do
    out[#out + 1] = ("%5d  %s"):format(i, lines[i])
  end
  if last < total then
    out[#out + 1] = ("… %d more lines; read from line %d"):format(total - last, last + 1)
  end
  local summary = (first == 1 and last == total) and (total .. " lines") or ("lines %d-%d of %d"):format(first, last, total)
  return table.concat(out, "\n"), summary
end

-- returns output (sent to the model), summary (shown in the chat), ok
function M.run(name, args)
  local fn = run[name]
  if not fn then
    return "error: unknown tool " .. tostring(name), "unknown tool", false
  end
  if type(args) ~= "table" then
    args = {}
  end
  local ok, out, summary = pcall(fn, args, root())
  if not ok then
    return "error: " .. tostring(out), "failed", false
  end
  if out == nil then
    return "error: " .. tostring(summary), summary, false
  end
  return cap(out), summary, true
end

return M
