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

function M.request(messages, cb)
  local opts = require("aporia.config").options
  local p = opts.providers[opts.provider]
  if not p then
    return cb("unknown provider: " .. tostring(opts.provider))
  end
  local key = M.resolve_key(p)
  if not key then
    return cb("no api key found for provider '" .. tostring(opts.provider) .. "' (tried api_key, " .. tostring(p.api_key_env) .. ", api_key_cmd)")
  end
  local body = vim.json.encode({
    model = p.model,
    messages = messages,
    stream = false,
  })
  local args = {
    "curl",
    "-sS",
    "-X",
    "POST",
    p.base_url .. "/chat/completions",
    "-H",
    "Content-Type: application/json",
    "-H",
    "Authorization: Bearer " .. (key or ""),
    "-d",
    body,
  }
  vim.system(args, { text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        return cb("curl failed (" .. res.code .. "): " .. vim.trim(res.stderr or ""))
      end
      local ok, data = pcall(vim.json.decode, res.stdout or "")
      if not ok then
        return cb("unparseable response: " .. tostring((res.stdout or ""):sub(1, 200)))
      end
      if data.error then
        return cb(data.error.message or vim.json.encode(data.error))
      end
      local choice = data.choices and data.choices[1]
      if not choice or not choice.message then
        return cb("no choices in response")
      end
      cb(nil, choice.message.content or "")
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
