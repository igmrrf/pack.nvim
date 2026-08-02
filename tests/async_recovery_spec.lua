local state = require("pack.state")
local loader = require("pack.loader")
local async = require("pack.async")
local pack = require("pack")

describe("pack.loader packadd failure (2.1)", function()
  it("marks a plugin 'error' on packadd failure and does not retry", function()
    state.init({ plugins = { "u/ghostplug" } }) -- never installed / not on packpath
    local errors = 0
    local orig = vim.notify
    vim.notify = function(msg, lvl)
      if lvl == vim.log.levels.ERROR and tostring(msg):find("ghostplug", 1, true) then
        errors = errors + 1
      end
    end

    loader.load("ghostplug")
    vim.notify = orig
    assert.equals("error", state.get_plugins()["ghostplug"].status)
    assert.equals(1, errors)

    -- Second load must be a no-op (guarded on "error"), not another failed attempt.
    vim.notify = function(msg, lvl)
      if lvl == vim.log.levels.ERROR and tostring(msg):find("ghostplug", 1, true) then
        errors = errors + 1
      end
    end
    loader.load("ghostplug")
    vim.notify = orig
    assert.equals(1, errors, "must not retry a plugin already marked error")
  end)
end)

describe("pack.async bounded concurrency (2.2)", function()
  it("runs queued work with at most `limit` in flight", function()
    local items = {}
    for i = 1, 12 do
      items[i] = i
    end
    local active, max_active, done_count = 0, 0, 0
    async.run_queued(items, function(_, done)
      active = active + 1
      max_active = math.max(max_active, active)
      vim.defer_fn(function()
        active = active - 1
        done_count = done_count + 1
        done()
      end, 10)
    end, 3)

    vim.wait(3000, function()
      return done_count == #items
    end)
    assert.equals(#items, done_count, "every item must complete")
    assert.is_true(max_active <= 3, "max concurrent was " .. max_active)
  end)

  it("excludes recently-checked plugins from outdated targets (cooldown)", function()
    state.init({ plugins = { "u/fresh.nvim", "u/stale.nvim" } })
    local plugins = state.get_plugins()
    plugins["fresh.nvim"].status = "installed"
    plugins["stale.nvim"].status = "installed"
    plugins["fresh.nvim"].checked_at = os.time()
    plugins["stale.nvim"].checked_at = os.time() - 100000
    async.outdated_cooldown = 300

    local names = {}
    for _, p in ipairs(async.outdated_targets()) do
      names[p.name] = true
    end
    assert.is_nil(names["fresh.nvim"], "fresh plugin is within cooldown, skip it")
    assert.is_true(names["stale.nvim"], "stale plugin is past cooldown, include it")
  end)
end)

describe("pack.async stuck-updating recovery (2.3)", function()
  local orig_native
  before_each(function()
    orig_native = pack.native_pack
  end)
  after_each(function()
    pack.native_pack = orig_native
  end)

  it("restores status if native update throws synchronously", function()
    state.init({ plugins = { "u/foo.nvim" } })
    local p = state.get_plugins()["foo.nvim"]
    p.status = "installed"
    pack.native_pack = {
      update = function()
        error("boom")
      end,
    }
    local orig_notify = vim.notify
    vim.notify = function() end
    async.update_plugins({ "foo.nvim" })
    vim.notify = orig_notify
    assert.equals("installed", p.status, "must not be left stuck in 'updating'")
  end)

  it("recovers plugins stuck in updating when no PackChanged event fires", function()
    state.init({ plugins = { "u/bar.nvim" } })
    local p = state.get_plugins()["bar.nvim"]
    p.status = "installed"
    pack.native_pack = {
      update = function() end, -- succeeds silently, emits no PackChanged(update)
    }
    async.update_recover_ms = 50
    async.update_plugins({ "bar.nvim" })
    assert.equals("updating", p.status, "status flips to updating up front")

    vim.wait(1000, function()
      return p.status ~= "updating"
    end)
    assert.equals("installed", p.status, "recovery timeout must restore the prior status")
  end)

  it("does not prematurely flip a plugin with pending commits (real update in flight)", function()
    state.init({ plugins = { "u/slow.nvim" } })
    local p = state.get_plugins()["slow.nvim"]
    p.status = "installed"
    state.set_behind("slow.nvim", 3) -- had real pending work -> a genuine update
    pack.native_pack = {
      -- Simulate a slow-but-real update: succeeds, PackChanged will fire *later*
      -- than the recover timer (here it never fires in the test window).
      update = function() end,
    }
    async.update_recover_ms = 50
    async.update_plugins({ "slow.nvim" })
    assert.equals("updating", p.status, "status flips to updating up front")

    -- Within 1 tick window: plugin with pending commits stays updating
    vim.wait(70)
    assert.equals("updating", p.status, "a real in-flight update is granted 1 tick grace period")

    -- After second tick window (2 ticks total): max deadline forces recovery even if PackChanged never fired
    vim.wait(300, function()
      return p.status ~= "updating"
    end)
    assert.equals("installed", p.status, "max recovery deadline forces recovery after 2 ticks")
  end)
end)
