local helpers = require("tests.helpers")
local search = require("pack.loader.search")
local state = require("pack.state")

-- Directly drive the package searcher installed by setup_package_searcher rather
-- than going through require() (which would then fall through to the real loaders
-- and error on a fixture module that does not exist on disk).
local function installed_searcher()
  local searchers = package.loaders or package.searchers
  return searchers[1]
end

describe("pack.loader.search package searcher", function()
  before_each(function()
    helpers.reset()
  end)

  after_each(function()
    search.uninstall_searcher()
  end)

  it("installs a single searcher at the front of package.loaders", function()
    search.setup_package_searcher(function() end)
    assert.is_function(installed_searcher())
    assert.is_true(search._searcher_installed)

    -- Idempotent: a second setup does not stack a second searcher.
    local before = #(package.loaders or package.searchers)
    search.setup_package_searcher(function() end)
    assert.equals(before, #(package.loaders or package.searchers))
  end)

  it("force-loads a lazy installed plugin when its module is required", function()
    state.init({ plugins = { { "user/foo.nvim", lazy = true } } })
    state.get_plugins()["foo.nvim"].status = "installed"

    local loaded = {}
    search.setup_package_searcher(function(name)
      loaded[name] = true
    end)

    installed_searcher()("foo") -- require("foo")
    assert.is_true(loaded["foo.nvim"], "requiring a lazy plugin's module must trigger its load")
  end)

  it("resolves hyphen/underscore module-name variants", function()
    state.init({ plugins = { { "user/my-plug.nvim", lazy = true } } })
    state.get_plugins()["my-plug.nvim"].status = "installed"

    local loaded = {}
    search.setup_package_searcher(function(name)
      loaded[name] = true
    end)

    installed_searcher()("my_plug") -- underscore variant of my-plug
    assert.is_true(loaded["my-plug.nvim"], "underscore variant of the module name must resolve")
  end)

  it("honors module = false as an opt-out from require-based loading", function()
    state.init({ plugins = { { "user/optout.nvim", lazy = true, module = false } } })
    state.get_plugins()["optout.nvim"].status = "installed"

    local loaded = {}
    search.setup_package_searcher(function(name)
      loaded[name] = true
    end)

    local result = installed_searcher()("optout")
    assert.is_nil(result)
    assert.is_nil(loaded["optout.nvim"], "module=false plugins must never force-load on require")
  end)

  it("declines a disabled plugin required inside a pcall (lets the require fail gracefully)", function()
    -- The searcher walks the call stack: if the require is inside a pcall the
    -- caller opted into handling failure, so it returns nil rather than a mock.
    -- (busted runs every `it` inside a pcall, which is exactly this case; the
    -- outside-pcall mock branch can't be exercised from within the harness.)
    state.init({ plugins = { { "user/disabled.nvim", lazy = true } } })
    state.set_disabled("disabled.nvim", true)

    search.setup_package_searcher(function() end)

    local result
    -- An explicit pcall frame guarantees the in_pcall detection sees a pcall.
    pcall(function()
      result = installed_searcher()("disabled")
    end)
    assert.is_nil(result, "a disabled plugin required within a pcall must resolve to nil, not a mock")
  end)

  it("suppresses lazy loading while ftdetect scripts are sourced (in_ftdetect guard)", function()
    -- setup_package_searcher dofiles the ftdetect cache with in_ftdetect=true; any
    -- require() during that window must be a no-op even when the searcher is already
    -- installed, else sourcing ftdetect would recursively drag lazy plugins in at
    -- startup. Install the searcher first, then re-run setup with a cache that
    -- require()s a lazy module, and confirm it did NOT force-load.
    state.init({ plugins = { { "user/ftguard.nvim", lazy = true } } })
    state.get_plugins()["ftguard.nvim"].status = "installed"

    local loaded = {}
    search.setup_package_searcher(function(name)
      loaded[name] = true
    end)
    assert.is_true(search._searcher_installed)

    local cache = vim.fn.tempname() .. ".lua"
    local f = io.open(cache, "w")
    f:write('pcall(require, "ftguard")\n')
    f:close()
    search._set_ftdetect_cache_path_for_testing(cache)

    -- Searcher already live; this re-source must run under the in_ftdetect guard.
    search.setup_package_searcher(function(name)
      loaded[name] = true
    end)

    assert.is_nil(loaded["ftguard.nvim"], "a require during ftdetect sourcing must not force-load")
    vim.fn.delete(cache)
  end)

  it("uninstall_searcher removes the global searcher (test isolation)", function()
    search.setup_package_searcher(function() end)
    local fn = installed_searcher()
    assert.is_function(fn)

    search.uninstall_searcher()
    assert.is_nil(search._searcher_installed)
    local searchers = package.loaders or package.searchers
    for _, s in ipairs(searchers) do
      assert.is_not_equal(fn, s, "the searcher must no longer be present after uninstall")
    end
  end)
end)
