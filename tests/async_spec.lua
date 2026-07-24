local async = require("pack.async")
local state = require("pack.state")
local persist = require("pack.persist")

describe("pack.async.parse_behind_count", function()
  it("parses a well-formed count with trailing newline", function()
    assert.equals(3, async.parse_behind_count("3\n"))
  end)

  it("parses zero", function()
    assert.equals(0, async.parse_behind_count("0"))
  end)

  it("returns nil for empty output", function()
    assert.is_nil(async.parse_behind_count(""))
  end)

  it("returns nil for garbage/error output", function()
    assert.is_nil(async.parse_behind_count("fatal: no upstream configured for branch"))
  end)

  it("returns nil for non-string input", function()
    assert.is_nil(async.parse_behind_count(nil))
  end)
end)

describe("pack.async.check_outdated", function()
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

  it("no-ops when plugin is disabled", function()
    state.init(config_with({ "user/foo.nvim" }))
    local p = state.get_plugins()["foo.nvim"]

    -- Mark as disabled
    state.set_disabled("foo.nvim", true)

    -- Call check_outdated directly with ineligible plugin
    async.check_outdated(p)

    -- After a short wait, verify nothing was spawned (no behind/checked_at updates)
    vim.wait(100)
    assert.is_nil(p.behind)
    assert.is_nil(p.checked_at)
  end)

  it("no-ops when plugin status is not installed or loaded", function()
    state.init(config_with({ "user/foo.nvim" }))
    local p = state.get_plugins()["foo.nvim"]

    -- Manually set status to 'missing' (ineligible)
    state.update_status("foo.nvim", "missing")

    -- Call check_outdated directly with ineligible plugin
    async.check_outdated(p)

    -- After a short wait, verify nothing was spawned (no behind/checked_at updates)
    vim.wait(100)
    assert.is_nil(p.behind)
    assert.is_nil(p.checked_at)
  end)

  it("clears stale outdated detail when behind reports 0", function()
    state.init(config_with({ "user/foo.nvim" }))
    local p = state.get_plugins()["foo.nvim"]

    -- Simulate leftover rich detail from a previous outdated check.
    state.set_outdated_detail("foo.nvim", {
      revision_before = "abc1234",
      revision_after = "def5678",
      upstream_branch = "main",
      pending_commits = { "abc1234 │ some old commit" },
    })
    assert.is_not_nil(p.revision_before)

    -- The plugin has since caught up (e.g. via a manual `git pull` outside
    -- the dashboard); a re-check should clear the stale detail once
    -- set_behind reports 0, not just leave it lingering.
    state.set_behind("foo.nvim", 0)
    state.set_outdated_detail("foo.nvim", {})

    assert.equals(0, p.behind)
    assert.is_nil(p.revision_before)
    assert.is_nil(p.revision_after)
    assert.is_nil(p.upstream_branch)
    assert.is_nil(p.pending_commits)
  end)

  it("runs the full check_outdated chain against a real local git repo", function()
    -- Build a real upstream repo with one commit.
    local upstream_dir = vim.fn.tempname() .. "-pack-upstream"
    vim.fn.mkdir(upstream_dir, "p")
    local function run(cmd, cwd)
      vim.fn.system(cmd)
      assert.equals(0, vim.v.shell_error, table.concat(cmd, " ") .. " failed")
    end

    run({ "git", "init", "-q", upstream_dir })
    run({ "git", "-C", upstream_dir, "config", "user.email", "pack-test@example.com" })
    run({ "git", "-C", upstream_dir, "config", "user.name", "pack-test" })
    vim.fn.writefile({ "hello" }, upstream_dir .. "/file.txt")
    run({ "git", "-C", upstream_dir, "add", "file.txt" })
    run({ "git", "-C", upstream_dir, "commit", "-q", "-m", "initial commit" })

    -- Clone it, simulating the plugin's install dir.
    local clone_dir = vim.fn.tempname() .. "-pack-clone"
    run({ "git", "clone", "-q", upstream_dir, clone_dir })

    -- Make a second, pending commit upstream that the clone doesn't have yet.
    vim.fn.writefile({ "hello", "world" }, upstream_dir .. "/file.txt")
    run({ "git", "-C", upstream_dir, "add", "file.txt" })
    run({ "git", "-C", upstream_dir, "commit", "-q", "-m", "second commit" })

    state.init(config_with({ "user/fixture.nvim" }))
    local fixture = state.get_plugins()["fixture.nvim"]
    fixture.dir = clone_dir
    fixture.status = "installed"
    fixture.disabled = false

    async.check_outdated(fixture)

    local ok = vim.wait(5000, function()
      return fixture.behind ~= nil and fixture.pending_commits ~= nil
    end, 20)
    assert.is_true(ok, "check_outdated did not complete in time; log:\n" .. table.concat(fixture.log, "\n"))

    assert.equals(1, fixture.behind)
    assert.is_not_nil(fixture.revision_before)
    assert.is_not_nil(fixture.revision_after)
    assert.matches("^%x%x%x%x+$", fixture.revision_before)
    assert.matches("^%x%x%x%x+$", fixture.revision_after)
    assert.is_not.equals(fixture.revision_before, fixture.revision_after)

    assert.is_table(fixture.pending_commits)
    assert.equals(1, #fixture.pending_commits)
    assert.matches("^%x%x%x%x+ │ second commit$", fixture.pending_commits[1])

    vim.fn.delete(upstream_dir, "rf")
    vim.fn.delete(clone_dir, "rf")
  end)
end)

describe("pack.async.parse_revision_pair", function()
  it("splits two-line rev-parse output", function()
    local before, after = async.parse_revision_pair("abc123\ndef456\n")
    assert.equals("abc123", before)
    assert.equals("def456", after)
  end)

  it("returns nils for empty output", function()
    local before, after = async.parse_revision_pair("")
    assert.is_nil(before)
    assert.is_nil(after)
  end)

  it("returns nils for non-string input", function()
    local before, after = async.parse_revision_pair(nil)
    assert.is_nil(before)
    assert.is_nil(after)
  end)
end)

describe("pack.async.parse_upstream_branch_name", function()
  it("strips a single remote-name prefix", function()
    assert.equals("main", async.parse_upstream_branch_name("origin/main\n"))
  end)

  it("only strips the first segment for a branch name containing slashes", function()
    assert.equals("feature/foo", async.parse_upstream_branch_name("origin/feature/foo"))
  end)

  it("returns the trimmed input when there is no remote prefix", function()
    assert.equals("main", async.parse_upstream_branch_name("main"))
  end)

  it("returns nil for empty or non-string input", function()
    assert.is_nil(async.parse_upstream_branch_name(""))
    assert.is_nil(async.parse_upstream_branch_name(nil))
  end)
end)

describe("pack.async.parse_pending_commits", function()
  it("splits multi-line git log output into a list", function()
    local commits = async.parse_pending_commits("abc123 │ fix: x\ndef456 │ feat: y")
    assert.same({ "abc123 │ fix: x", "def456 │ feat: y" }, commits)
  end)

  it("returns an empty list for empty or non-string output", function()
    assert.same({}, async.parse_pending_commits(""))
    assert.same({}, async.parse_pending_commits(nil))
  end)
end)

describe("pack.async.install", function()
  local function make_local_upstream()
    local upstream_dir = vim.fn.tempname() .. "-pack-install-upstream"
    vim.fn.mkdir(upstream_dir, "p")
    local function run(cmd)
      vim.fn.system(cmd)
      assert.equals(0, vim.v.shell_error, table.concat(cmd, " ") .. " failed")
    end
    run({ "git", "init", "-q", upstream_dir })
    run({ "git", "-C", upstream_dir, "config", "user.email", "pack-test@example.com" })
    run({ "git", "-C", upstream_dir, "config", "user.name", "pack-test" })
    vim.fn.writefile({ "hello" }, upstream_dir .. "/file.txt")
    run({ "git", "-C", upstream_dir, "add", "file.txt" })
    run({ "git", "-C", upstream_dir, "commit", "-q", "-m", "initial commit" })
    return upstream_dir
  end

  it("clones a missing non-lazy plugin and hands off to loader.load", function()
    local upstream_dir = make_local_upstream()
    local install_dir = vim.fn.tempname() .. "-pack-install-dir"

    state.init({ install_path = vim.fn.tempname() .. "-pack-install", plugins = { "user/fixture-nonlazy.nvim" } })
    local p = state.get_plugins()["fixture-nonlazy.nvim"]
    p.url = upstream_dir
    p.dir = install_dir
    p.lazy = false

    local loader = require("pack.loader")
    local load_called_with = nil
    local original_load = loader.load
    loader.load = function(name) load_called_with = name end

    async.install(p)

    local ok = vim.wait(5000, function() return p.status ~= "installing" and p.status ~= "missing" end, 20)
    vim.wait(200, function() return load_called_with ~= nil end, 10)

    loader.load = original_load

    assert.is_true(ok, "install did not finish in time; log:\n" .. table.concat(p.log, "\n"))
    assert.equals("installed", p.status)
    assert.equals(1, vim.fn.isdirectory(install_dir))
    assert.equals("fixture-nonlazy.nvim", load_called_with)

    vim.fn.delete(upstream_dir, "rf")
    vim.fn.delete(install_dir, "rf")
  end)

  it("clones a missing lazy plugin and wires up its triggers instead of loading it immediately", function()
    -- Regression test: loader.init() only registers cmd/event/ft/keys
    -- triggers for plugins already on disk at startup. A lazy plugin
    -- installed live via :Pack sync used to end up "installed" with no
    -- trigger ever wired up - it would silently never lazy-load until the
    -- next Neovim restart.
    local upstream_dir = make_local_upstream()
    local install_dir = vim.fn.tempname() .. "-pack-install-dir"

    state.init({ install_path = vim.fn.tempname() .. "-pack-install", plugins = { "user/fixture-lazy.nvim" } })
    local p = state.get_plugins()["fixture-lazy.nvim"]
    p.url = upstream_dir
    p.dir = install_dir
    p.lazy = true
    p.cmd = "PackFixtureLazyCmd"

    local loader = require("pack.loader")
    local load_called = false
    local setup_triggers_called_with = nil
    local original_load = loader.load
    local original_setup_triggers = loader.setup_triggers
    loader.load = function() load_called = true end
    loader.setup_triggers = function(plugin) setup_triggers_called_with = plugin.name end

    async.install(p)

    local ok = vim.wait(5000, function() return p.status ~= "installing" and p.status ~= "missing" end, 20)
    vim.wait(200, function() return setup_triggers_called_with ~= nil end, 10)

    loader.load = original_load
    loader.setup_triggers = original_setup_triggers

    assert.is_true(ok, "install did not finish in time; log:\n" .. table.concat(p.log, "\n"))
    assert.equals("installed", p.status)
    assert.is_false(load_called, "a lazy plugin must not be eagerly loaded on install")
    assert.equals(
      "fixture-lazy.nvim",
      setup_triggers_called_with,
      "a freshly-installed lazy plugin must have its triggers wired up so it can lazy-load without a Neovim restart"
    )

    vim.fn.delete(upstream_dir, "rf")
    vim.fn.delete(install_dir, "rf")
  end)
end)

describe("pack.async.sync", function()
  it("skips disabled plugins entirely", function()
    local state = require("pack.state")
    local persist = require("pack.persist")
    local tmp_path = vim.fn.tempname() .. "-disabled.json"
    persist._set_path_for_testing(tmp_path)

    state.init({ install_path = vim.fn.tempname() .. "-install", plugins = { "user/foo.nvim" } })
    state.set_disabled("foo.nvim", true)

    local install_called = false
    local original_install = async.install
    async.install = function() install_called = true end

    async.sync({})

    async.install = original_install
    assert.is_false(install_called)

    if vim.fn.filereadable(tmp_path) == 1 then
      vim.fn.delete(tmp_path)
    end
    persist._set_path_for_testing(nil)
  end)
end)
