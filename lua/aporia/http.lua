local M = {}

function M.resolve_key(p)
  if p.api_key and p.api_key ~= "" then
    return p.api_key
  end
  if p.api_key_env and p.api_key_env ~= "" then
    local from_env = os.getenv(p.api_key_env)
    if from_env and from_env ~= "" then
      return from_env
    end
  end
  if p.api_key_cmd and p.api_key_cmd ~= "" then
    local res = vim.system({ "sh", "-c", p.api_key_cmd }, { text = true }):wait()
    if res.code == 0 then
      local key = vim.trim(res.stdout or "")
      if key ~= "" then
        return key
      end
    end
  end
  return nil
end

local function error_message(e)
  if type(e) == "table" then
    return e.message or vim.json.encode(e)
  end
  return tostring(e)
end

-- Server-sent events from an OpenAI-compatible /chat/completions stream.
-- feed() takes stdout in arbitrary chunks; finish() returns err, content.
-- on_delta(text, kind) gets kind "content", or "reasoning" for a thinking
-- model's reasoning, which is not part of the reply.
-- A body that is not SSE at all (an HTTP error) is kept and decoded at the end.
function M.sse_parser(on_delta)
  local pending, raw, pieces, err = "", {}, {}, nil
  local done = false

  local function line(l)
    l = l:gsub("\r$", "")
    local data = l:match("^data:%s?(.*)$")
    if not data then
      if l ~= "" and not l:match("^[:%a]+:") then
        raw[#raw + 1] = l
      end
      return
    end
    if data == "[DONE]" then
      done = true
      return
    end
    local ok, ev = pcall(vim.json.decode, data)
    if not ok or type(ev) ~= "table" then
      return
    end
    if ev.error then
      err = err or error_message(ev.error)
      return
    end
    local choice = ev.choices and ev.choices[1]
    local delta = choice and choice.delta or {}
    local thought = delta.reasoning_content or delta.reasoning
    if type(thought) == "string" and thought ~= "" then
      on_delta(thought, "reasoning")
    end
    if type(delta.content) == "string" and delta.content ~= "" then
      pieces[#pieces + 1] = delta.content
      on_delta(delta.content, "content")
    end
  end

  local parser = {}
  function parser.feed(chunk)
    pending = pending .. chunk
    while true do
      local nl = pending:find("\n", 1, true)
      if not nl then
        break
      end
      line(pending:sub(1, nl - 1))
      pending = pending:sub(nl + 1)
    end
  end

  function parser.finish()
    if pending ~= "" then
      line(pending)
      pending = ""
    end
    local content = table.concat(pieces)
    if err then
      return err, content
    end
    if #pieces == 0 and #raw > 0 then
      local body = table.concat(raw, "\n")
      local ok, data = pcall(vim.json.decode, body)
      if ok and type(data) == "table" and data.error then
        return error_message(data.error), content
      end
      return "unparseable response: " .. body:sub(1, 200), content
    end
    if #pieces == 0 and not done then
      return "empty response", content
    end
    return nil, content
  end

  return parser
end

-- Streams a reply. on_delta(text, kind) runs for each piece as it arrives and
-- cb(err, content) once at the end, content being everything received (also
-- on error, so a reply cut off mid-way is not lost). Both run on the main loop.
-- This is the contract the chat UI relies on, whichever engine produces it.
function M.request(messages, cb, on_delta)
  on_delta = on_delta or function() end
  local opts = require("aporia.config").options
  local p = opts.providers[opts.provider]
  if not p then
    return cb("unknown provider: " .. tostring(opts.provider), "")
  end
  local key = M.resolve_key(p)
  if not key then
    return cb(
      "no api key found for provider '"
        .. tostring(opts.provider)
        .. "' (tried api_key, "
        .. tostring(p.api_key_env)
        .. ", api_key_cmd)",
      ""
    )
  end
  local body = vim.json.encode({
    model = p.model,
    messages = messages,
    stream = true,
  })
  local args = {
    "curl",
    "-sS",
    "-N",
    "-X",
    "POST",
    p.base_url .. "/chat/completions",
    "-H",
    "Content-Type: application/json",
    "-H",
    "Accept: text/event-stream",
    "-H",
    "Authorization: Bearer " .. key,
    "-d",
    body,
  }
  local parser = M.sse_parser(on_delta)
  -- stdout arrives on the event loop; vim.schedule keeps the chunks in order
  return vim.system(args, {
    text = true,
    stdout = function(_, data)
      if data then
        vim.schedule(function()
          parser.feed(data)
        end)
      end
    end,
  }, function(res)
    vim.schedule(function()
      local err, content = parser.finish()
      if res.code ~= 0 then
        err = "curl failed (" .. res.code .. "): " .. vim.trim(res.stderr or "")
      end
      cb(err, content)
    end)
  end)
end

function M.get(url, cb)
  vim.system({ "curl", "-sSL", "--max-time", "20", url }, { text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        return cb("fetch failed (" .. res.code .. "): " .. vim.trim(res.stderr or ""))
      end
      cb(nil, res.stdout or "")
    end)
  end)
end

return M
