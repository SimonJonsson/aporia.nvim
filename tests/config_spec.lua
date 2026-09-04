local config = require("aporia.config")

describe("aporia.config", function()
  before_each(function()
    config.options = vim.deepcopy(config.defaults)
  end)

  it("keeps defaults without opts", function()
    config.setup()
    assert.equals("baseten", config.options.provider)
    assert.equals("confirm", config.options.fetch.mode)
    assert.equals(15, config.options.context.padding)
  end)

  it("merges user options deep", function()
    config.setup({
      provider = "openai",
      fetch = { mode = "auto" },
    })
    assert.equals("openai", config.options.provider)
    assert.equals("auto", config.options.fetch.mode)
    assert.equals(2, config.options.fetch.max_fetches_per_turn)
  end)

  it("resolves all default keymaps", function()
    local m = config.options.mappings
    for _, key in ipairs({ "question", "hint", "reframe", "steps", "rootcause", "log", "toggle", "add_selection", "add_buffer" }) do
      assert.is_string(m[key])
      assert.is_true(#m[key] > 0)
    end
  end)
end)
