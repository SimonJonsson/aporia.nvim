local M = {}

local TRAPS = { "question", "hint", "reframe", "steps", "rootcause", "log" }
local SUBCOMMANDS = vim.list_extend({ "toggle", "reset", "add", "addbuffer" }, TRAPS)

function M.register()
  vim.api.nvim_create_user_command("Aporia", function(o)
    local chat = require("aporia.chat")
    local sub = vim.trim(o.args)
    if sub == "" or sub == "toggle" then
      return chat.toggle()
    end
    if sub == "reset" then
      return chat.reset()
    end
    if sub == "add" then
      return require("aporia.context").stage_selection()
    end
    if sub == "addbuffer" then
      return require("aporia.context").stage_buffer()
    end
    if vim.tbl_contains(TRAPS, sub) then
      return chat.trap(sub)
    end
    vim.notify("aporia: unknown subcommand '" .. sub .. "'", vim.log.levels.WARN)
  end, {
    nargs = "?",
    complete = function()
      return SUBCOMMANDS
    end,
    desc = "Aporia: your AI tutor",
  })
end

return M
