local http = require("aporia.http")

local function ev(text)
  return "data: " .. vim.json.encode({ choices = { { delta = { content = text } } } }) .. "\n\n"
end

local function run(chunks)
  local deltas = {}
  local p = http.sse_parser(function(t)
    deltas[#deltas + 1] = t
  end)
  for _, c in ipairs(chunks) do
    p.feed(c)
  end
  local err, content = p.finish()
  return err, content, deltas
end

describe("aporia sse parser", function()
  it("joins deltas into the reply", function()
    local err, content, deltas = run({ ev("Hel"), ev("lo"), "data: [DONE]\n\n" })
    assert.is_nil(err)
    assert.equals("Hello", content)
    assert.same({ "Hel", "lo" }, deltas)
  end)

  it("handles events split across chunks and CRLF line ends", function()
    local s = (ev("a") .. ev("b")):gsub("\n", "\r\n") .. "data: [DONE]"
    local chunks = {}
    for i = 1, #s, 7 do
      chunks[#chunks + 1] = s:sub(i, i + 6)
    end
    local err, content = run(chunks)
    assert.is_nil(err)
    assert.equals("ab", content)
  end)

  it("skips comments, other fields and empty or role-only deltas", function()
    local role = "data: " .. vim.json.encode({ choices = { { delta = { role = "assistant" } } } }) .. "\n\n"
    local err, content, deltas =
      run({ ": keep-alive\n\n", "event: message\n", role, ev(""), ev("x"), "data: [DONE]\n\n" })
    assert.is_nil(err)
    assert.equals("x", content)
    assert.same({ "x" }, deltas)
  end)

  it("keeps reasoning out of the reply", function()
    local thought = "data: " .. vim.json.encode({ choices = { { delta = { reasoning_content = "hmm" } } } }) .. "\n\n"
    local kinds = {}
    local p = http.sse_parser(function(_, kind)
      kinds[#kinds + 1] = kind
    end)
    p.feed(thought .. ev("hi") .. "data: [DONE]\n\n")
    local err, content = p.finish()
    assert.is_nil(err)
    assert.equals("hi", content)
    assert.same({ "reasoning", "content" }, kinds)
  end)

  it("reports a plain JSON error body", function()
    assert.equals("invalid api key", (run({ '{"error": {"message": "invalid api key"}}\n' })))
    assert.equals("Authentication required.", (run({ '{"error": "Authentication required."}\n' })))
  end)

  it("reports an error event and keeps what arrived before it", function()
    local err, content = run({ ev("part"), 'data: {"error": {"message": "overloaded"}}\n\n' })
    assert.equals("overloaded", err)
    assert.equals("part", content)
  end)

  it("reports an empty stream", function()
    assert.equals("empty response", (run({})))
  end)
end)
