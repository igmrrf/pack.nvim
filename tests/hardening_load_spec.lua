local state = require("pack.state")
local loader = require("pack.loader")
local persist = require("pack.persist")

-- Create a real, packadd-able plugin under a fresh packpath entry so
-- loader.load() -> packadd actually sources something. The sourced file bumps
-- _G.PACK_TEST_LOADED[name] so a test can assert whether (and how often) the
-- plugin was loaded.
local function fake_plugin(name)
  local root = vim.fn.tempname()
  local pdir = root .. "/pack/pht/opt/" .. name
  vim.fn.mkdir(pdir .. "/plugin", "p")
  vim.fn.writefile({
    "_G.PACK_TEST_LOADED = _G.PACK_TEST_LOADED or {}",
    ('_G.PACK_TEST_LOADED[%q] = (_G.PACK_TEST_LOADED[%q] or 0) + 1'):format(name, name),
  }, pdir .. "/plugin/init.lua")
  vim.opt.packpath:prepend(root)
  return pdir
end

local function config_with(plugins)
  return { plugins = plugins }
end

describe("pack.loader load-path hardening", function()
  local tmp_path

  before_each(function()
    tmp_path = vim.fn.tempname() .. "-pack-extra.json"
    persist._set_path_for_testing(tmp_path)
    _G.PACK_TEST_LOADED = {}
  end)

  after_each(function()
    if vim.fn.filereadable(tmp_path) == 1 then
      vim.fn.delete(tmp_path)
    end
    persist._set_path_for_testing(nil)
    _G.PACK_TEST_LOADED = nil
  end)

  it("terminates (no stack overflow) on a circular dependency and loads both", function()
    fake_plugin("a")
    fake_plugin("b")
    -- Nest the deps so the back-edge (b -> a) actually registers; two flat
    -- top-level specs would dedup and drop the cycle.
    state.init(config_with({
      { "u/a", dependencies = { { "u/b", dependencies = { "u/a" } } } },
    }))

    local ok = pcall(loader.load, "a")
    assert.is_true(ok, "circular dependency must not recurse forever")
    assert.equals(1, _G.PACK_TEST_LOADED["a"])
    assert.equals(1, _G.PACK_TEST_LOADED["b"])
  end)

  it("loads a native-style dependency keyed by name (not URL basename)", function()
    fake_plugin("customdep")
    state.init(config_with({
      {
        "u/parent",
        dependencies = { { src = "https://github.com/u/realrepo", name = "customdep" } },
      },
    }))
    fake_plugin("parent")

    loader.load("parent")
    assert.equals(1, _G.PACK_TEST_LOADED["customdep"], "dependency resolved by name must load")
  end)

  it("does not load a disabled plugin via M.load", function()
    fake_plugin("disabledone")
    state.init(config_with({ "u/disabledone" }))
    state.get_plugins()["disabledone"].disabled = true

    loader.load("disabledone")
    assert.is_nil(_G.PACK_TEST_LOADED["disabledone"])
    assert.are_not.equal("loaded", state.get_plugins()["disabledone"].status)
  end)
end)

describe("pack.state.derive_name", function()
  it("derives from a bare owner/repo string", function()
    assert.equals("repo.nvim", state.derive_name("owner/repo.nvim"))
  end)

  it("strips a trailing .git", function()
    assert.equals("repo", state.derive_name("owner/repo.git"))
  end)

  it("honors an explicit name on a native-style spec", function()
    assert.equals("custom", state.derive_name({ src = "https://x/y", name = "custom" }))
  end)

  it("honors an explicit name on a shorthand spec", function()
    assert.equals("custom", state.derive_name({ "owner/repo", name = "custom" }))
  end)

  it("prefers `as` over name and basename", function()
    assert.equals("aliased", state.derive_name({ "owner/repo", name = "custom", as = "aliased" }))
  end)
end)
