local config = require("aporia.config")
local store = require("aporia.store")

describe("aporia project store", function()
  local cwd, project

  before_each(function()
    cwd = vim.fn.getcwd()
    project = vim.fs.normalize(vim.fn.resolve(vim.fn.tempname()))
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.mkdir(project .. "/src", "p")
    vim.cmd.cd(project .. "/src")
    config.options.persist.enabled = true
  end)

  after_each(function()
    config.options.persist.enabled = false
    vim.cmd.cd(cwd)
    vim.fn.delete(project, "rf")
  end)

  it("finds the project root above cwd and ignores its own directory", function()
    assert.equals(project, store.root())
    local dir = store.dir()
    assert.equals(project .. "/.aporia", dir)
    assert.same({ "*" }, vim.fn.readfile(dir .. "/.gitignore"))
  end)

  it("saves nothing without a project root", function()
    vim.fn.delete(project .. "/.git", "rf")
    assert.is_nil(store.root())
    assert.is_false(store.save("assist", "x", {}))
    assert.equals(0, vim.fn.isdirectory(project .. "/.aporia"))
  end)

  it("loads the newest session per mode", function()
    store.save("assist", "20260101-000000", { { role = "user", question = "old" } })
    store.save("assist", "20260102-000000", { { role = "user", question = "new" } })
    store.save("teach", "20260103-000000", { { role = "user", question = "teach" } })
    local latest = store.load_latest("assist")
    assert.equals("20260102-000000", latest.id)
    assert.equals("new", latest.messages[1].question)
    assert.equals("teach", store.load_latest("teach").messages[1].question)
  end)

  it("restores a chat conversation after a restart", function()
    local http = require("aporia.http")
    local real_request = http.request
    http.request = function(_, cb)
      cb(nil, "saved reply")
    end
    package.loaded["aporia.chat"] = nil
    local c = require("aporia.chat")
    c.open()
    vim.api.nvim_buf_set_lines(c.input_bufnr, 0, -1, false, { "remember me" })
    c.submit()
    c.hide()
    http.request = real_request

    package.loaded["aporia.chat"] = nil
    local fresh = require("aporia.chat")
    fresh.open()
    assert.equals("remember me", fresh.messages[1].question)
    assert.equals("saved reply", fresh.messages[2].content)
    fresh.hide()
    package.loaded["aporia.chat"] = nil
  end)

  describe("delete-all-sessions", function()
    local real_confirm = vim.fn.confirm
    local c

    before_each(function()
      store.save("assist", "20260101-000000", { { role = "user", question = "a" } })
      store.save("assist", "20260102-000000", { { role = "user", question = "b" } })
      store.save("teach", "20260103-000000", { { role = "user", question = "t" } })
      package.loaded["aporia.chat"] = nil
      c = require("aporia.chat")
      c.open()
    end)

    after_each(function()
      vim.fn.confirm = real_confirm
      c.hide()
      package.loaded["aporia.chat"] = nil
    end)

    it("counts every saved session", function()
      assert.equals(3, store.count())
    end)

    it("deletes all sessions and the open conversations on yes", function()
      local asked
      vim.fn.confirm = function(msg)
        asked = msg
        return 1
      end
      assert.equals("b", c.messages[1].question)
      c.delete_all_sessions()
      assert.is_truthy(asked:find("3 saved aporia sessions", 1, true))
      assert.equals(0, store.count())
      assert.equals(0, vim.fn.isdirectory(project .. "/.aporia/sessions"))
      assert.equals(0, #c.sessions.assist)
      assert.equals(0, #c.sessions.teach)
      assert.is_nil(store.load_latest("assist"))
    end)

    it("keeps everything on no", function()
      vim.fn.confirm = function()
        return 2
      end
      c.delete_all_sessions()
      assert.equals(3, store.count())
      assert.equals("b", c.messages[1].question)
    end)

    it("does not resurrect the deleted conversation on the next message", function()
      vim.fn.confirm = function()
        return 1
      end
      c.delete_all_sessions()
      local http = require("aporia.http")
      local real_request = http.request
      http.request = function(_, cb)
        cb(nil, "fresh reply")
      end
      vim.api.nvim_buf_set_lines(c.input_bufnr, 0, -1, false, { "fresh" })
      c.submit()
      http.request = real_request
      assert.equals(1, store.count())
      local latest = store.load_latest("assist")
      assert.equals("fresh", latest.messages[1].question)
      assert.equals(2, #latest.messages)
    end)
  end)
end)
