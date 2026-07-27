-- Clear any cached modules
package.loaded["pack.state"] = nil
package.loaded["pack.persist"] = nil

local state = require("pack.state")
local persist = require("pack.persist")

describe("pack.state", function()
  local tmp_path

  before_each(function()
    tmp_path = vim.fn.tempname() .. "-pack-disabled.json"
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
      install_path = vim.fn.tempname() .. "-pack-install",
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

  it("reconcile_from_native promotes installed->loaded when dir is on runtimepath", function()
    state.init(config_with({ "user/foo.nvim" }))
    local p = state.get_plugins()["foo.nvim"]
    -- A plugin native itself packadd-ed (e.g. bootstrapped pack.nvim) is active
    -- on rtp but never ran through our load_fn, so it sits at "installed".
    local rtp_dir = vim.api.nvim_list_runtime_paths()[1]
    p.status = "installed"

    local fake_native = {
      get = function()
        return { { spec = { name = "foo.nvim" }, path = rtp_dir, rev = "deadbee" } }
      end,
    }
    state.reconcile_from_native(fake_native)

    assert.equals("loaded", p.status)
  end)

  it("reconcile_from_native leaves installed when dir is not on runtimepath", function()
    state.init(config_with({ "user/foo.nvim" }))
    local p = state.get_plugins()["foo.nvim"]
    p.status = "installed"

    local fake_native = {
      get = function()
        return { { spec = { name = "foo.nvim" }, path = "/nowhere/not/on/rtp/foo.nvim" } }
      end,
    }
    state.reconcile_from_native(fake_native)

    assert.equals("installed", p.status)
  end)

  it("declared plugins are marked managed = true", function()
    state.init(config_with({ "user/foo.nvim" }))
    assert.is_true(state.get_plugins()["foo.nvim"].managed)
  end)

  it("reconcile_from_native adopts an unknown native plugin as managed = false", function()
    state.init(config_with({ "user/foo.nvim" }))
    local rtp_dir = vim.api.nvim_list_runtime_paths()[1]
    local fake_native = {
      get = function()
        return {
          { spec = { name = "foo.nvim" }, path = "/some/foo.nvim", rev = "aaa" },
          { spec = { name = "adopted.nvim", src = "https://github.com/x/adopted.nvim" }, path = rtp_dir, rev = "bbb" },
        }
      end,
    }
    state.reconcile_from_native(fake_native)
    local a = state.get_plugins()["adopted.nvim"]
    assert.is_not_nil(a)
    assert.is_false(a.managed)
    assert.equals("https://github.com/x/adopted.nvim", a.url)
    assert.equals("loaded", a.status) -- path is on runtimepath
    assert.equals(50, a.priority)
    assert.is_false(a.disabled)
    assert.is_false(a.lazy)
    assert.same({}, a.log)
    assert.same({}, a.dependencies)
    assert.is_false(a.is_local)
  end)

  it("reconcile_from_native does not overwrite a managed entry on name collision", function()
    state.init(config_with({ "user/foo.nvim" }))
    local before = state.get_plugins()["foo.nvim"]
    before.status = "installed"
    local fake_native = {
      get = function()
        return { { spec = { name = "foo.nvim" }, path = "/new/path/foo.nvim", rev = "ccc" } }
      end,
    }
    state.reconcile_from_native(fake_native)
    local after = state.get_plugins()["foo.nvim"]
    assert.is_true(after.managed) -- still managed, not clobbered
    assert.equals("/new/path/foo.nvim", after.dir) -- dir still refreshed
    assert.equals("ccc", after.rev)
  end)

  it("reconcile_from_native bumps generation only when it adopts", function()
    state.init(config_with({ "user/foo.nvim" }))
    local gen0 = state.generation
    state.reconcile_from_native({ get = function()
      return { { spec = { name = "foo.nvim" }, path = "/p/foo.nvim" } }
    end })
    assert.equals(gen0, state.generation) -- no new plugin, no bump
    state.reconcile_from_native({ get = function()
      return { { spec = { name = "new.nvim", src = "https://github.com/x/new.nvim" }, path = "/p/new.nvim" } }
    end })
    assert.equals(gen0 + 1, state.generation) -- one adopted
  end)

  it("init resets previously registered plugins", function()
    state.init(config_with({ "user/foo.nvim", commit = "abc" }))
    -- re-init with a different plugin set must NOT retain the old ones
    state.init(config_with({ "user/bar.nvim" }))
    local plugins = state.get_plugins()
    assert.is_nil(plugins["foo.nvim"], "stale plugin from prior init must be cleared")
    assert.is_not_nil(plugins["bar.nvim"])
  end)

  it("infers lazy = true when event, ft, cmd, or keys are present without explicit lazy", function()
    state.init({
      plugins = {
        { "user/eventplug.nvim", event = "BufReadPost" },
        { "user/ftplug.nvim", ft = "markdown" },
        { "user/cmdplug.nvim", cmd = "Cmd" },
        { "user/keyplug.nvim", keys = "<leader>k" },
        { "user/eagerplug.nvim", event = "BufReadPost", lazy = false },
      },
    })
    local p = state.get_plugins()
    assert.is_true(p["eventplug.nvim"].lazy)
    assert.is_true(p["ftplug.nvim"].lazy)
    assert.is_true(p["cmdplug.nvim"].lazy)
    assert.is_true(p["keyplug.nvim"].lazy)
    assert.is_false(p["eagerplug.nvim"].lazy)
  end)
end)

