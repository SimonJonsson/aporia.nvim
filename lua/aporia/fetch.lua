local M = {}

local PATTERN = "^FETCH:%s*(%S+)"

function M.extract(content)
  local urls = {}
  for line in content:gmatch("[^\n]+") do
    local url = line:match(PATTERN)
    if url then
      urls[#urls + 1] = url
    end
  end
  return urls
end

function M.process(content)
  local opts = require("aporia.config").options.fetch
  local urls = M.extract(content)
  if #urls == 0 or opts.mode == "links" then
    return
  end
  local context = require("aporia.context")
  local http = require("aporia.http")
  for i, url in ipairs(urls) do
    if i > opts.max_fetches_per_turn then
      vim.notify("aporia: fetch limit reached, ignoring " .. url, vim.log.levels.WARN)
      break
    end
    if opts.mode == "confirm" and vim.fn.confirm("aporia: fetch " .. url .. "?", "&yes\n&no", 2) ~= 1 then
      goto continue
    end
    http.get(url, function(err, body)
      if err then
        return vim.notify("aporia: " .. err, vim.log.levels.ERROR)
      end
      context.stage_doc(url, body)
    end)
    ::continue::
  end
end

return M
