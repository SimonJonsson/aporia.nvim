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
    if p.api_key_env == "" then
      vim.health.ok("no api key required (local provider)")
    elseif not os.getenv(p.api_key_env) then
      vim.health.warn("env " .. p.api_key_env .. " is not set")
    else
      vim.health.ok("env " .. p.api_key_env .. " is set")
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
