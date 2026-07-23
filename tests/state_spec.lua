local state = require("packui.state")
local persist = require("packui.persist")

describe("packui.state", function()
  local tmp_path

  before_each(function()
    tmp_path = vim.fn.tempname() .. "-packui-disabled.json"
    persist._set_path_for_testing(tmp_path)
  end)

  after_each(function()
    if vim.fn.filereadable(tmp_path) == 1 then
      vim.fn.delete(tmp_path)
    end
    persist._set_path_for_testing(nil)
  end)

  local function config_with(plugins)
    return {
      install_path = vim.fn.tempname() .. "-packui-install",
      plugins = plugins,
    }
  end

  it("normalizes a bare string plugin spec and defaults disabled to false", function()
    state.init(config_with({ "user/foo.nvim" }))
    local p = state.get_plugins()["foo.nvim"]
    assert.is_not_nil(p)
    assert.equals("https://github.com/user/foo.nvim", p.url)
    assert.is_false(p.disabled)
  end)

  it("marks plugins disabled from the persisted set", function()
    persist.save({ ["foo.nvim"] = true })
    state.init(config_with({ "user/foo.nvim", "user/bar.nvim" }))
    local plugins = state.get_plugins()
    assert.is_true(plugins["foo.nvim"].disabled)
    assert.is_false(plugins["bar.nvim"].disabled)
  end)

  it("set_disabled updates in-memory state and persists", function()
    state.init(config_with({ "user/foo.nvim" }))
    state.set_disabled("foo.nvim", true)
    assert.is_true(state.get_plugins()["foo.nvim"].disabled)
    assert.is_true(persist.load()["foo.nvim"])
  end)

  it("set_behind stores the commit-behind count and a timestamp", function()
    state.init(config_with({ "user/foo.nvim" }))
    state.set_behind("foo.nvim", 3)
    local p = state.get_plugins()["foo.nvim"]
    assert.equals(3, p.behind)
    assert.is_number(p.checked_at)
  end)

  it("set_disabled on nonexistent plugin does not error and leaves plugin nil", function()
    state.init(config_with({ "user/foo.nvim" }))
    local ok = pcall(state.set_disabled, "nonexistent.nvim", true)
    assert.is_true(ok)
    assert.is_nil(state.get_plugins()["nonexistent.nvim"])
  end)

  it("set_behind on nonexistent plugin does not error and leaves plugin nil", function()
    state.init(config_with({ "user/foo.nvim" }))
    local ok = pcall(state.set_behind, "nonexistent.nvim", 3)
    assert.is_true(ok)
    assert.is_nil(state.get_plugins()["nonexistent.nvim"])
  end)

  it("set_outdated_detail stores revision/branch/commit fields together", function()
    state.init(config_with({ "user/foo.nvim" }))
    state.set_outdated_detail("foo.nvim", {
      revision_before = "abc123",
      revision_after = "def456",
      upstream_branch = "main",
      pending_commits = { "def456 │ fix: something" },
    })
    local p = state.get_plugins()["foo.nvim"]
    assert.equals("abc123", p.revision_before)
    assert.equals("def456", p.revision_after)
    assert.equals("main", p.upstream_branch)
    assert.same({ "def456 │ fix: something" }, p.pending_commits)
  end)

  it("set_outdated_detail no-ops for an unknown plugin name", function()
    state.init(config_with({ "user/foo.nvim" }))
    local ok = pcall(state.set_outdated_detail, "nonexistent.nvim", { revision_before = "x" })
    assert.is_true(ok)
    assert.is_nil(state.get_plugins()["nonexistent.nvim"])
  end)
end)
