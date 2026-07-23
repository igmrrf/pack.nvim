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
end)
