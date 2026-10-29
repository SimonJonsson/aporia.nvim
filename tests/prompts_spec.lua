local prompts = require("aporia.prompts")

describe("aporia.prompts", function()
  it("has all six traps", function()
    for _, name in ipairs({ "question", "hint", "reframe", "steps", "rootcause", "log" }) do
      assert.is_truthy(prompts.traps[name], "missing trap: " .. name)
      assert.is_truthy(prompts.traps[name].template)
    end
  end)

  it("every mode forbids solutions and demands verification", function()
    for _, mode in ipairs({ "assist", "teach" }) do
      local sys = prompts.system(mode)
      assert.is_truthy(sys:find("Never write the solution"))
      assert.is_truthy(sys:find("verification path"))
      assert.is_truthy(sys:find("FETCH:"))
      assert.is_truthy(sys:find("Mode: " .. mode))
    end
  end)

  it("only teach mode is Socratic", function()
    assert.is_truthy(prompts.system("teach"):find("Ask one question at a time"))
    assert.is_nil(prompts.system("assist"):find("Ask one question at a time"))
    assert.is_nil(prompts.system("assist"):find("tutor"))
  end)

  it("hint ladder stops at level 3", function()
    assert.is_truthy(prompts.traps.hint.template:find("level 3"))
    assert.is_nil(prompts.traps.hint.template:match("level 4"))
  end)
end)
