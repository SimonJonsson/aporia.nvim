local M = {}

function M.setup(opts)
  local config = require("aporia.config")
  config.setup(opts)
  if vim.g.aporia_did_setup then
    return M
  end
  vim.g.aporia_did_setup = true
  require("aporia.commands").register()
  local m = config.options.mappings
  local map = vim.keymap.set
  local function trap(name)
    return function()
      require("aporia.chat").trap(name)
    end
  end
  map({ "n", "v" }, m.question, trap("question"), { desc = "Aporia: question check (Forming)" })
  map({ "n", "v" }, m.hint, trap("hint"), { desc = "Aporia: hint ladder (Dislodging)" })
  map({ "n", "v" }, m.reframe, trap("reframe"), { desc = "Aporia: reframe (Assumption)" })
  map({ "n", "v" }, m.steps, trap("steps"), { desc = "Aporia: step audit (Location)" })
  map({ "n", "v" }, m.rootcause, trap("rootcause"), { desc = "Aporia: root-cause challenge (Achievement)" })
  map({ "n", "v" }, m.log, trap("log"), { desc = "Aporia: log what I learned (Progression)" })
  map({ "n", "v", "i" }, m.toggle, function()
    vim.cmd("stopinsert")
    require("aporia.chat").toggle()
  end, { desc = "Aporia: toggle chat" })
  map({ "n", "v" }, m.add_selection, function()
    if require("aporia.context").stage_selection() then
      require("aporia.chat").open()
    end
  end, { desc = "Aporia: stage selection" })
  map({ "n", "v" }, m.add_buffer, function()
    require("aporia.context").stage_buffer()
    require("aporia.chat").open()
  end, { desc = "Aporia: stage buffer" })
  return M
end

return M
