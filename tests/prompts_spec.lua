local prompts = require("aporia.prompts")

describe("aporia.prompts", function()
  it("has all six traps", function()
    for _, name in ipairs({ "question", "hint", "reframe", "steps", "rootcause", "log" }) do
      assert.is_truthy(prompts.traps[name], "missing trap: " .. name)
      assert.is_truthy(prompts.traps[name].template)
    end
  end)

  it("system prompt forbids solutions and demands verification", function()
    assert.is_truthy(prompts.system_prompt:find("Never write the solution"))
    assert.is_truthy(prompts.system_prompt:find("verification path"))
    assert.is_truthy(prompts.system_prompt:find("FETCH:"))
  end)

  it("hint ladder stops at level 3", function()
    assert.is_truthy(prompts.traps.hint.template:find("level 3"))
    assert.is_nil(prompts.traps.hint.template:match("level 4"))
  end)
end)
