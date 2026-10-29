local tools = require("aporia.tools")
local store = require("aporia.store")

describe("aporia tools", function()
  local dir, real_root

  before_each(function()
    dir = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(dir .. "/src", "p")
    vim.fn.writefile({ "local x = 1", "return x" }, dir .. "/src/a.lua")
    vim.fn.writefile({ "SECRET=1" }, dir .. "/.env")
    vim.fn.writefile({ ".env" }, dir .. "/.gitignore")
    vim.system({ "git", "init", "-q", dir }):wait()
    real_root = store.root
    store.root = function()
      return dir
    end
  end)

  after_each(function()
    store.root = real_root
    vim.fn.delete(dir, "rf")
  end)

  it("lists files without ignored ones", function()
    local out, summary, ok = tools.run("list_files", {})
    assert.is_true(ok)
    assert.is_truthy(out:find("src/a.lua", 1, true))
    assert.is_nil(out:find(".env", 1, true))
    assert.equals("2 files", summary)
  end)

  it("reads a file with line numbers and a range", function()
    local out, summary, ok = tools.run("read_file", { path = "src/a.lua", start_line = 2 })
    assert.is_true(ok)
    assert.is_truthy(out:find("lines 2%-2 of 2"))
    assert.is_truthy(out:find("2  return x", 1, true))
    assert.equals("lines 2-2 of 2", summary)
  end)

  it("reads an open buffer as it is, unsaved edits included", function()
    vim.cmd("edit " .. dir .. "/src/a.lua")
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "local x = 2" })
    local out = tools.run("read_file", { path = "src/a.lua" })
    assert.is_truthy(out:find("local x = 2", 1, true))
    vim.cmd("bwipeout!")
  end)

  it("refuses paths outside the project, in .git and ignored by git", function()
    for _, path in ipairs({ "../", "/etc/hosts", ".git/config", ".env" }) do
      local out, _, ok = tools.run("read_file", { path = path })
      assert.is_false(ok, path)
      assert.is_truthy(out:find("^error:"), path)
    end
  end)

  it("searches file contents", function()
    local out, summary, ok = tools.run("grep", { pattern = "return" })
    assert.is_true(ok)
    assert.is_truthy(out:find("src/a.lua:2:return x", 1, true))
    assert.equals("1 match", summary)
    assert.equals("no matches", (tools.run("grep", { pattern = "nothing_here_at_all" })))
  end)

  it("reports unknown tools and bad arguments as errors", function()
    assert.is_false(select(3, tools.run("rm_rf", {})))
    assert.is_false(select(3, tools.run("read_file", {})))
  end)

  it("labels steps for the chat", function()
    assert.equals("read src/a.lua:2-", tools.label("read_file", { path = "src/a.lua", start_line = 2 }))
    assert.equals('search "foo" in lua', tools.label("grep", { pattern = "foo", path = "lua" }))
    assert.equals("list files", tools.label("list_files", {}))
  end)
end)
