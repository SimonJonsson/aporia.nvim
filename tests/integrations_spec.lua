local c = require("aporia.chat")

-- a stand-in for no-neck-pain: same global state field, same API shape
local calls
local function fake_nnp(enabled)
  calls = {}
  _G.NoNeckPain = { state = { enabled = enabled } }
  package.loaded["no-neck-pain"] = {
    disable = function()
      calls[#calls + 1] = "disable"
      vim.defer_fn(function()
        _G.NoNeckPain.state.enabled = false
      end, 5)
    end,
    enable = function()
      calls[#calls + 1] = "enable"
      _G.NoNeckPain.state.enabled = true
    end,
  }
end

local function settle()
  vim.wait(200, function()
    return false
  end)
end

describe("aporia integrations", function()
  local events

  before_each(function()
    events = {}
    vim.api.nvim_create_autocmd("User", {
      group = vim.api.nvim_create_augroup("aporia_spec_events", { clear = true }),
      pattern = { "AporiaSidebarOpen", "AporiaSidebarClose" },
      callback = function(ev)
        events[#events + 1] = ev.match
      end,
    })
  end)

  after_each(function()
    c.hide()
    _G.NoNeckPain = nil
    package.loaded["no-neck-pain"] = nil
  end)

  it("pauses no-neck-pain while the sidebar is open and resumes it on close", function()
    fake_nnp(true)
    c.open()
    settle()
    assert.same({ "disable" }, calls)
    assert.is_true(vim.g.aporia_sidebar)
    c.hide()
    settle()
    assert.same({ "disable", "enable" }, calls)
    assert.is_false(vim.g.aporia_sidebar)
    assert.same({ "AporiaSidebarOpen", "AporiaSidebarClose" }, events)
  end)

  it("leaves no-neck-pain alone when it was already off", function()
    fake_nnp(false)
    c.open()
    settle()
    c.hide()
    settle()
    assert.same({}, calls)
  end)

  it("does not resume no-neck-pain while nvim is quitting", function()
    fake_nnp(true)
    c.open()
    settle()
    c.hide({ quitting = true })
    settle()
    assert.same({ "disable" }, calls)
  end)

  it("works without no-neck-pain installed", function()
    c.open()
    settle()
    assert.is_true(vim.g.aporia_sidebar)
    c.hide()
    assert.is_false(vim.g.aporia_sidebar)
  end)
end)
