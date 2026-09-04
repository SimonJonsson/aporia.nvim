local M = {}

function M.check()
  vim.health.start("aporia")
  local config = require("aporia.config").options
  local p = config.providers[config.provider]
  if not p then
    vim.health.error("unknown provider: " .. tostring(config.provider))
  else
    vim.health.info(("provider: %s (%s)"):format(config.provider, p.base_url))
    if p.model == "" then
      vim.health.warn("no model configured for provider '" .. config.provider .. "'")
    else
      vim.health.ok("model: " .. p.model)
    end
    local key = require("aporia.http").resolve_key(p)
    if p.api_key_env == "" and p.api_key_cmd == "" and not p.api_key then
      vim.health.ok("no api key required (local provider)")
    elseif key then
      vim.health.ok("api key found via "
        .. (p.api_key and "api_key" or (os.getenv(p.api_key_env or "") and p.api_key_env or "api_key_cmd")))
    else
      vim.health.warn("no api key found (checked api_key, env " .. tostring(p.api_key_env) .. ", api_key_cmd)")
    end
  end
  if vim.fn.executable("curl") == 1 then
    vim.health.ok("curl found")
  else
    vim.health.error("curl not found (required for all requests)")
  end
  local f = io.open(vim.fn.expand(config.log_file), "a")
  if f then
    f:close()
    vim.health.ok("log file writable: " .. config.log_file)
  else
    vim.health.warn("log file not writable: " .. config.log_file)
  end
end

return M
