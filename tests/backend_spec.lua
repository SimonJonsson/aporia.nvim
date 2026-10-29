local backend = require("aporia.backend")

-- the Lua half of the protocol, driven the way the backend drives it
describe("aporia backend events", function()
  local function settle()
    vim.wait(50, function()
      return false
    end)
  end

  it("routes deltas, tool steps and the end of a turn", function()
    local h = {}
    -- pretend the process is running: request() only needs a channel
    local real_start, real_notify = backend.start, vim.rpcnotify
    backend.start = function()
      return 1
    end
    local sent
    vim.rpcnotify = function(_, method, payload)
      sent = { method = method, payload = payload }
    end
    require("aporia.config").options.providers.test = { base_url = "http://x/v1", model = "m" }
    local real_provider = require("aporia.config").options.provider
    require("aporia.config").options.provider = "test"

    h.deltas, h.steps = {}, {}
    backend.request({ { role = "user", content = "q" } }, function(err, content)
      h.err, h.content = err, content
    end, function(text, kind)
      h.deltas[#h.deltas + 1] = kind .. ":" .. text
    end, {
      tools = true,
      on_step = function(step)
        h.steps[#h.steps + 1] = step.status .. ":" .. step.label
      end,
    })
    local id = sent.payload.id
    assert.equals("chat", sent.method)
    assert.equals(3, #sent.payload.tools)
    assert.is_nil(sent.payload.provider.api_key)

    backend._event({ id = id, type = "delta", kind = "content", text = "Let me look." })
    local out = backend._tool(id, "list_files", "{}")
    assert.is_truthy(out:find("lua/aporia/backend.lua", 1, true))
    assert.equals("error: arguments are not valid JSON: {", backend._tool(id, "grep", "{"))
    backend._event({ id = id, type = "done", content = "Let me look.\n\nDone." })
    settle()

    assert.same({ "content:Let me look." }, h.deltas)
    assert.same({ "running:list files", "done:list files" }, h.steps)
    assert.is_nil(h.err)
    assert.equals("Let me look.\n\nDone.", h.content)
    -- after the end, the turn is gone
    assert.equals("error: the request was cancelled", backend._tool(id, "list_files", "{}"))

    backend.start, vim.rpcnotify = real_start, real_notify
    require("aporia.config").options.provider = real_provider
  end)
end)
