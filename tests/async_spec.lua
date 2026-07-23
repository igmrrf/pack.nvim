local async = require("packui.async")
local state = require("packui.state")
local persist = require("packui.persist")

describe("packui.async.parse_behind_count", function()
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

describe("packui.async.check_outdated", function()
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
    local upstream_dir = vim.fn.tempname() .. "-packui-upstream"
    vim.fn.mkdir(upstream_dir, "p")
    local function run(cmd, cwd)
      vim.fn.system(cmd)
      assert.equals(0, vim.v.shell_error, table.concat(cmd, " ") .. " failed")
    end

    run({ "git", "init", "-q", upstream_dir })
    run({ "git", "-C", upstream_dir, "config", "user.email", "packui-test@example.com" })
    run({ "git", "-C", upstream_dir, "config", "user.name", "packui-test" })
    vim.fn.writefile({ "hello" }, upstream_dir .. "/file.txt")
    run({ "git", "-C", upstream_dir, "add", "file.txt" })
    run({ "git", "-C", upstream_dir, "commit", "-q", "-m", "initial commit" })

    -- Clone it, simulating the plugin's install dir.
    local clone_dir = vim.fn.tempname() .. "-packui-clone"
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

describe("packui.async.parse_revision_pair", function()
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

describe("packui.async.parse_upstream_branch_name", function()
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

describe("packui.async.parse_pending_commits", function()
  it("splits multi-line git log output into a list", function()
    local commits = async.parse_pending_commits("abc123 │ fix: x\ndef456 │ feat: y")
    assert.same({ "abc123 │ fix: x", "def456 │ feat: y" }, commits)
  end)

  it("returns an empty list for empty or non-string output", function()
    assert.same({}, async.parse_pending_commits(""))
    assert.same({}, async.parse_pending_commits(nil))
  end)
end)

describe("packui.async.sync", function()
  it("skips disabled plugins entirely", function()
    local state = require("packui.state")
    local persist = require("packui.persist")
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
