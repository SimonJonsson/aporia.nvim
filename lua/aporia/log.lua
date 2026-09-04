local M = {}

function M.parse(content)
  local learned, still
  for line in content:gmatch("[^\n]+") do
    learned = learned or line:match("^learned:%s*(.+)")
    still = still or line:match("^still needed AI for:%s*(.+)")
  end
  return learned, still
end

function M.run(content)
  local learned, still = M.parse(content)
  if not learned or not still then
    return vim.notify("aporia: no learned/still-needed lines found in reply", vim.log.levels.WARN)
  end
  learned = vim.trim(vim.fn.input("learned: ", learned))
  still = vim.trim(vim.fn.input("still needed AI for: ", still))
  local file = require("aporia.config").options.log_file
  local f = io.open(vim.fn.expand(file), "a")
  if not f then
    return vim.notify("aporia: cannot write " .. file, vim.log.levels.ERROR)
  end
  f:write(os.date("%Y-%m-%d") .. " | learned: " .. learned .. " | still needed AI for: " .. still .. "\n")
  f:close()
  vim.notify("aporia: appended to " .. file)
end

return M
