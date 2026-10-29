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

  it("makes ids unique within a mode", function()
    local first = store.new_id("assist", project)
    store.save("assist", first, { { role = "user", question = "x" } })
    assert.are_not.equals(first, store.new_id("assist", project))
  end)

  it("lists sessions newest first with their opening question", function()
    store.save("assist", "20260101-000000", { { role = "user", question = "old" }, { role = "assistant", content = "r" } })
    store.save("assist", "20260102-000000", {
      { role = "user", parts = { { text = "from parts" } } },
      { role = "user", question = "second" },
    })
    local list = store.list("assist")
    assert.same({ "20260102-000000", "20260101-000000" }, vim.tbl_map(function(s)
      return s.id
    end, list))
    assert.equals("from parts", list[1].first)
    assert.equals(2, list[1].turns)
    assert.equals(1, list[2].turns)
  end)

  describe("two instances on one project", function()
    local http = require("aporia.http")
    local real_request = http.request
    local c

    local function send(text)
      vim.api.nvim_buf_set_lines(c.input_bufnr, 0, -1, false, { text })
      c.submit()
    end

    before_each(function()
      store.save("assist", "20260101-000000", { { role = "user", question = "shared" }, { role = "assistant", content = "r" } })
      http.request = function(_, cb)
        cb(nil, "ok")
      end
      package.loaded["aporia.chat"] = nil
      c = require("aporia.chat")
      c.open()
    end)

    after_each(function()
      http.request = real_request
      c.hide()
      package.loaded["aporia.chat"] = nil
    end)

    it("keeps writing the same file while nobody else does", function()
      send("one")
      send("two")
      assert.equals(1, #store.list("assist"))
      assert.equals(6, #store.load("assist", "20260101-000000").messages)
    end)

    it("continues in a copy when another instance wrote the file", function()
      -- the other Neovim adds its own turn to the shared file
      vim.wait(20, function()
        return false
      end)
      store.save("assist", "20260101-000000", {
        { role = "user", question = "shared" },
        { role = "assistant", content = "r" },
        { role = "user", question = "theirs" },
      })
      send("mine")
      local other = store.load("assist", "20260101-000000").messages
      assert.equals("theirs", other[3].question)
      local list = store.list("assist")
      assert.equals(2, #list)
      assert.are_not.equals("20260101-000000", c.session_ids.assist)
      local copy = store.load("assist", c.session_ids.assist).messages
      assert.equals("mine", copy[3].question)
      -- and from then on, the copy is ours: no further forks
      send("again")
      assert.equals(2, #store.list("assist"))
    end)
  end)

  describe("resume", function()
    local real_select = vim.ui.select
    local c

    before_each(function()
      store.save("assist", "20260101-000000", { { role = "user", question = "older" } })
      store.save("assist", "20260102-000000", { { role = "user", question = "newer" } })
      package.loaded["aporia.chat"] = nil
      c = require("aporia.chat")
      c.open()
    end)

    after_each(function()
      vim.ui.select = real_select
      c.hide()
      package.loaded["aporia.chat"] = nil
    end)

    it("offers the mode's sessions, marks the open one, and loads the pick", function()
      assert.equals("newer", c.messages[1].question)
      local labels
      vim.ui.select = function(items, opts, on_choice)
        labels = vim.tbl_map(opts.format_item, items)
        on_choice(items[2])
      end
      c.resume()
      assert.is_truthy(labels[1]:find("^• 2026%-01%-02 00:00 · 1 turn · newer"))
      assert.is_truthy(labels[2]:find("^  2026%-01%-01 00:00 · 1 turn · older"))
      assert.equals("older", c.messages[1].question)
      assert.equals("20260101-000000", c.session_ids.assist)
    end)

    it("leaves the conversation alone when the pick is cancelled", function()
      vim.ui.select = function(_, _, on_choice)
        on_choice(nil)
      end
      c.resume()
      assert.equals("newer", c.messages[1].question)
    end)
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
