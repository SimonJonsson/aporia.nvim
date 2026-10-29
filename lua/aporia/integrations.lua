-- Plugins that rearrange windows and would fight the sidebar column.
-- While the sidebar is open, vim.g.aporia_sidebar is true and the User
-- events AporiaSidebarOpen / AporiaSidebarClose fire, so user config can
-- hold its own layout automation off.
local M = {}

local nnp_paused = false

local function nnp_enabled()
  local nnp = rawget(_G, "NoNeckPain")
  return nnp and nnp.state and nnp.state.enabled or false
end

local function enabled(name)
  return require("aporia.config").options.integrations[name]
end

-- run after_layout once no-neck-pain has closed its padding windows;
-- its disable() is debounced onto a timer
local function when_nnp_off(after_layout)
  local tries = 0
  local function check()
    if not nnp_enabled() or tries >= 50 then
      return after_layout()
    end
    tries = tries + 1
    vim.defer_fn(check, 10)
  end
  vim.defer_fn(check, 10)
end

function M.on_open(after_layout)
  vim.g.aporia_sidebar = true
  vim.api.nvim_exec_autocmds("User", { pattern = "AporiaSidebarOpen" })
  if enabled("no_neck_pain") and nnp_enabled() then
    nnp_paused = true
    require("no-neck-pain").disable()
    when_nnp_off(after_layout)
  end
end

-- quitting: leave no-neck-pain off, re-enabling would open windows mid-quit
function M.on_close(quitting)
  vim.g.aporia_sidebar = false
  vim.api.nvim_exec_autocmds("User", { pattern = "AporiaSidebarClose" })
  if nnp_paused then
    nnp_paused = false
    if not quitting then
      vim.schedule(function()
        require("no-neck-pain").enable()
      end)
    end
  end
end

return M
