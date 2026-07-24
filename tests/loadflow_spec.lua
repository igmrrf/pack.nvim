local loader = require("pack.loader")
local state = require("pack.state")
local persist = require("pack.persist")

describe("pack.loader load_fn / flush_pending", function()
  local tmp_path
  local orig_load, orig_setup_triggers
  local loaded, triggered

  before_each(function()
    tmp_path = vim.fn.tempname() .. "-pack-disabled.json"
    persist._set_path_for_testing(tmp_path)

    -- Observe ordering without touching real packadd/runtimepath.
    loaded, triggered = {}, {}
    orig_load = loader.load
    orig_setup_triggers = loader.setup_triggers
    loader.load = function(name) table.insert(loaded, name) end
    loader.setup_triggers = function(p) table.insert(triggered, p.name) end
  end)

  after_each(function()
    loader.load = orig_load
    loader.setup_triggers = orig_setup_triggers
    if vim.fn.filereadable(tmp_path) == 1 then vim.fn.delete(tmp_path) end
    persist._set_path_for_testing(nil)
  end)

  local function config_with(plugins)
    return { install_path = vim.fn.tempname() .. "-pack-install", plugins = plugins }
  end

  -- Simulate native vim.pack calling our load callback for every installed plugin.
  local function simulate_native_add()
    for name, p in pairs(state.get_plugins()) do
      loader.load_fn({ spec = { name = name, data = state.to_native_spec(p).data }, path = "/fake/" .. name })
    end
  end

  it("load_fn records the on-disk path and marks the plugin installed", function()
    state.init(config_with({ "user/foo.nvim" }))
    local p = state.get_plugins()["foo.nvim"]
    loader.load_fn({ spec = { name = "foo.nvim" }, path = "/fake/foo.nvim" })
    assert.equals("/fake/foo.nvim", p.dir)
    assert.equals("installed", p.status)
  end)

  it("loads eager plugins highest-priority first", function()
    state.init(config_with({
      { "user/low.nvim", priority = 10 },
      { "user/high.nvim", priority = 100 },
      { "user/mid.nvim", priority = 50 },
    }))
    simulate_native_add()
    loader.flush_pending()
    assert.same({ "high.nvim", "mid.nvim", "low.nvim" }, loaded)
    assert.same({}, triggered)
  end)

  it("wires triggers for lazy plugins instead of loading them", function()
    state.init(config_with({
      { "user/eager.nvim" },
      { "user/lazy.nvim", lazy = true, cmd = "LazyCmd" },
    }))
    simulate_native_add()
    loader.flush_pending()
    assert.same({ "eager.nvim" }, loaded)
    assert.same({ "lazy.nvim" }, triggered)
  end)

  it("skips disabled plugins entirely", function()
    state.init(config_with({ "user/foo.nvim", "user/bar.nvim" }))
    state.set_disabled("foo.nvim", true)
    simulate_native_add()
    loader.flush_pending()
    assert.same({ "bar.nvim" }, loaded)
  end)

  it("skips a plugin whose cond is false (no load, no triggers)", function()
    state.init(config_with({
      { "user/on.nvim" },
      { "user/off.nvim", cond = false, lazy = true, cmd = "OffCmd" },
    }))
    simulate_native_add()
    loader.flush_pending()
    assert.same({ "on.nvim" }, loaded)
    assert.same({}, triggered)
  end)

  it("runs init before the plugin loads", function()
    local order = {}
    loader.load = function(name) table.insert(order, "load:" .. name) end
    state.init(config_with({
      { "user/foo.nvim", init = function() table.insert(order, "init:foo.nvim") end },
    }))
    simulate_native_add()
    loader.flush_pending()
    assert.same({ "init:foo.nvim", "load:foo.nvim" }, order)
  end)

  it("does not reload an already-loaded plugin", function()
    state.init(config_with({ "user/foo.nvim" }))
    simulate_native_add()
    state.update_status("foo.nvim", "loaded")
    loader.flush_pending()
    assert.same({}, loaded)
  end)
end)
