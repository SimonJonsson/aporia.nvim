-- The Rust backend (backend/): Neovim starts it on first use and talks
-- msgpack-RPC over its stdio. It runs the agent loop, streams the reply
-- and calls back into Neovim to run tools (aporia.tools). The protocol is
-- documented in backend/crates/aporia-core/src/protocol.rs.
--
-- request() keeps aporia.http's contract, so the chat UI does not care
-- which one answers; without a built binary the chat uses aporia.http.
local M = {}

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")

local chan = nil
local next_id = 0
local active = {} -- id -> { cb, on_delta, on_step }
local stderr = {}

local function options()
  return require("aporia.config").options.backend
end

-- the configured command, else the most recently built binary in backend/
function M.cmd()
  local configured = options().cmd
  if configured then
    return vim.fn.executable(configured) == 1 and configured or nil
  end
  local best, best_mtime
  for _, profile in ipairs({ "release", "debug" }) do
    local path = vim.fs.joinpath(plugin_root, "backend", "target", profile, "aporia")
    local stat = vim.uv.fs_stat(path)
    if stat and vim.fn.executable(path) == 1 and (not best_mtime or stat.mtime.sec > best_mtime) then
      best, best_mtime = path, stat.mtime.sec
    end
  end
  return best
end

function M.available()
  return options().enabled and M.cmd() ~= nil
end

local function fail_all(message)
  local pending = active
  active = {}
  for _, h in pairs(pending) do
    h.cb(message, h.content or "")
  end
end

function M.start()
  if chan then
    return chan
  end
  local cmd = M.cmd()
  if not cmd then
    return nil, "aporia backend not built (make backend)"
  end
  stderr = {}
  local id = vim.fn.jobstart({ cmd }, {
    rpc = true,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then
          stderr[#stderr + 1] = line
        end
      end
    end,
    on_exit = function(_, code)
      chan = nil
      local why = stderr[#stderr]
      fail_all("aporia backend exited (" .. code .. ")" .. (why and (": " .. why) or ""))
    end,
  })
  if id <= 0 then
    return nil, "could not start " .. cmd
  end
  chan = id
  return chan
end

function M.stop()
  if chan then
    vim.fn.jobstop(chan)
    chan = nil
  end
end

-- synchronous round trip, for :checkhealth
function M.ping()
  local c, err = M.start()
  if not c then
    return nil, err
  end
  local ok, res = pcall(vim.rpcrequest, c, "ping")
  if not ok then
    return nil, tostring(res)
  end
  return res
end

-- Same contract as aporia.http.request, plus:
--   opts.tools    offer the tools in aporia.tools
--   opts.on_step  called with a step table when a tool starts and again
--                 when it finishes: { label, status = "running"|"done"|"error", detail }
-- Returns a handle with cancel().
function M.request(messages, cb, on_delta, opts)
  opts = opts or {}
  local c, err = M.start()
  if not c then
    return cb(err, "")
  end
  local config = require("aporia.config").options
  local p = config.providers[config.provider]
  if not p then
    return cb("unknown provider: " .. tostring(config.provider), "")
  end
  local key = require("aporia.http").resolve_key(p)
  local needs_key = p.api_key or (p.api_key_env or "") ~= "" or (p.api_key_cmd or "") ~= ""
  if needs_key and not key then
    return cb("no api key found for provider '" .. tostring(config.provider) .. "'", "")
  end
  next_id = next_id + 1
  local id = next_id
  active[id] = {
    cb = cb,
    on_delta = on_delta or function() end,
    on_step = opts.on_step or function() end,
    content = "",
  }
  vim.rpcnotify(c, "chat", {
    id = id,
    provider = { base_url = p.base_url, model = p.model, api_key = key },
    messages = messages,
    tools = opts.tools and require("aporia.tools").specs or {},
    max_rounds = options().max_rounds,
  })
  return {
    cancel = function()
      if active[id] then
        active[id] = nil
        pcall(vim.rpcnotify, c, "cancel", id)
      end
    end,
  }
end

-- called by the backend through nvim_exec_lua
function M._event(ev)
  -- the backend is waiting on this call; let it go and update the UI after
  vim.schedule(function()
    local h = active[ev.id]
    if not h then
      return
    end
    if ev.type == "delta" then
      if ev.kind == "content" then
        h.content = h.content .. ev.text
      end
      h.on_delta(ev.text, ev.kind)
    elseif ev.type == "done" then
      active[ev.id] = nil
      h.cb(nil, ev.content)
    elseif ev.type == "error" then
      active[ev.id] = nil
      h.cb(ev.message, ev.content)
    end
  end)
end

-- called by the backend through nvim_exec_lua; returns what the model sees
function M._tool(id, name, args_json)
  local h = active[id]
  if not h then
    return "error: the request was cancelled"
  end
  local ok, args = pcall(vim.json.decode, args_json ~= "" and args_json or "{}")
  if not ok or type(args) ~= "table" then
    return "error: arguments are not valid JSON: " .. tostring(args_json)
  end
  local tools = require("aporia.tools")
  local step = { label = tools.label(name, args), status = "running" }
  h.on_step(step)
  vim.cmd("redraw")
  local output, summary, success = tools.run(name, args)
  step.status = success and "done" or "error"
  step.detail = summary
  h.on_step(step)
  return output
end

return M
