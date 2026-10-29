local c = require("aporia.chat")
local http = require("aporia.http")

describe("aporia request history", function()
  local real_request = http.request
  local sent

  before_each(function()
    c.sessions = { assist = {}, teach = {} }
    c.set_mode("assist")
    c.busy = false
    sent = {}
  end)

  after_each(function()
    http.request = real_request
    c.sessions = { assist = {}, teach = {} }
    c.set_mode("assist")
    c.busy = false
  end)

  it("keeps failed replies out of the history sent to the model", function()
    http.request = function(msgs, cb)
      sent[#sent + 1] = msgs
      cb(#sent == 1 and "no api key" or nil, "ok")
    end
    table.insert(c.messages, { role = "user", question = "first", parts = { { text = "first" } }, time = "" })
    c._request()
    assert.is_true(c.messages[#c.messages].error)
    table.insert(c.messages, { role = "user", question = "second", parts = { { text = "second" } }, time = "" })
    c._request()
    local roles = vim.tbl_map(function(m)
      return m.role
    end, sent[2])
    assert.same({ "system", "user", "user" }, roles)
  end)

  it("sends the system prompt of the current mode", function()
    http.request = function(msgs, cb)
      sent[#sent + 1] = msgs
      cb(nil, "ok")
    end
    table.insert(c.messages, { role = "user", question = "q", parts = { { text = "q" } }, time = "" })
    c.set_mode("assist")
    c._request()
    assert.is_truthy(sent[1][1].content:find("Mode: assist"))
    c.set_mode("teach")
    c._request()
    assert.is_truthy(sent[2][1].content:find("Mode: teach"))
    c.set_mode("assist")
  end)

  it("keeps assist and teach as separate conversations", function()
    table.insert(c.messages, { role = "user", question = "a", parts = { { text = "a" } }, time = "" })
    c.set_mode("teach")
    assert.equals(0, #c.messages)
    table.insert(c.messages, { role = "user", question = "t", parts = { { text = "t" } }, time = "" })
    c.set_mode("assist")
    assert.equals("a", c.messages[1].question)
    assert.equals(1, #c.messages)
  end)

  it("delivers a reply to its own conversation after a mode switch", function()
    local pending
    http.request = function(_, cb)
      pending = cb
    end
    table.insert(c.messages, { role = "user", question = "a", parts = { { text = "a" } }, time = "" })
    c._request()
    c.set_mode("teach")
    pending(nil, "assist reply")
    assert.equals(0, #c.messages)
    assert.equals("assist reply", c.sessions.assist[2].content)
  end)
end)

describe("aporia streaming", function()
  local real_request = http.request

  before_each(function()
    c.sessions = { assist = {}, teach = {} }
    c.set_mode("assist")
    c.busy = false
  end)

  after_each(function()
    http.request = real_request
    c.sessions = { assist = {}, teach = {} }
    c.set_mode("assist")
    c.busy = false
  end)

  it("shows the reply as it arrives and finishes it in place", function()
    local done, delta
    http.request = function(_, cb, on_delta)
      done, delta = cb, on_delta
    end
    table.insert(c.messages, { role = "user", question = "q", parts = { { text = "q" } }, time = "" })
    c._request()
    local reply = c.messages[2]
    assert.is_true(reply.pending)
    delta("let me think", "reasoning")
    assert.equals("Thinking…", reply.content)
    delta("Hel", "content")
    delta("lo", "content")
    vim.wait(500, function()
      return reply.content == "Hello"
    end)
    assert.equals("Hello", reply.content)
    assert.is_true(c.busy)
    done(nil, "Hello there")
    assert.is_false(c.busy)
    assert.equals(2, #c.messages)
    assert.equals("Hello there", c.messages[2].content)
    assert.is_nil(c.messages[2].pending)
  end)

  it("keeps a cut-off reply visible but out of the history", function()
    local sent = {}
    http.request = function(msgs, cb)
      sent[#sent + 1] = msgs
      if #sent == 1 then
        cb("curl failed (18): transfer closed", "half a rep")
      else
        cb(nil, "ok")
      end
    end
    table.insert(c.messages, { role = "user", question = "a", parts = { { text = "a" } }, time = "" })
    c._request()
    assert.is_true(c.messages[2].error)
    assert.is_truthy(c.messages[2].content:find("^half a rep"))
    assert.is_truthy(c.messages[2].content:find("ERROR: curl failed"))
    table.insert(c.messages, { role = "user", question = "b", parts = { { text = "b" } }, time = "" })
    c._request()
    local roles = vim.tbl_map(function(m)
      return m.role
    end, sent[2])
    assert.same({ "system", "user", "user" }, roles)
  end)
end)
