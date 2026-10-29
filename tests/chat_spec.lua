local c = require("aporia.chat")
local http = require("aporia.http")

describe("aporia request history", function()
  local real_request = http.request
  local sent

  before_each(function()
    c.messages = {}
    c.busy = false
    sent = {}
  end)

  after_each(function()
    http.request = real_request
    c.messages = {}
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

end)
