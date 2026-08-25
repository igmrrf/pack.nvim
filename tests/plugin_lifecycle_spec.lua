local state = require("pack.state")
local loader = require("pack.loader")
local persist = require("pack.persist")

-- packadd-able fake plugin that records its load order into _G.PACK_ORDER.
local function fake_plugin(name, extra_line)
  local root = vim.fn.tempname()
  local pdir = root .. "/pack/ph4/opt/" .. name
  vim.fn.mkdir(pdir .. "/plugin", "p")
  vim.fn.writefile({
    "_G.PACK_ORDER = _G.PACK_ORDER or {}",
    ("table.insert(_G.PACK_ORDER, %q)"):format(name),
    extra_line or "",
  }, pdir .. "/plugin/init.lua")
  vim.opt.packpath:prepend(root)
  return pdir
end

describe("pack.state auto config uses runtime opts (4.x)", function()
  it("passes the plugin's current opts, not the opts captured at normalize time", function()
    package.loaded["stubmod"] = { setup = function(o) _G.STUB_OPTS = o end }
    state.init({ plugins = { { "u/stubmod", main = "stubmod", opts = { a = 1 } } } })
    local p = state.get_plugins()["stubmod"]
    p.opts = { a = 2 } -- runtime mutation (e.g. via a later merge)
    p.config({ path = "", spec = p }, p.opts)
    assert.same({ a = 2 }, _G.STUB_OPTS)
    package.loaded["stubmod"] = nil
    _G.STUB_OPTS = nil
  end)

  it("resolves default main by probing the lua/ dir for a hyphen->underscore module", function()
    -- Repo basename is hyphenated (neovim-tips) but the module underscores it
    -- (require("neovim_tips")). A real lua/neovim_tips/init.lua on disk lets the
    -- probe pick the underscore variant; package.preload stubs the actual load.
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/lua/neovim_tips", "p")
    vim.fn.writefile({ "return {}" }, root .. "/lua/neovim_tips/init.lua")
    package.preload["neovim_tips"] = function()
      return { setup = function(o) _G.NT_OPTS = o end }
    end

    state.init({ plugins = { { "saxon1964/neovim-tips", opts = { daily_tip = 0 } } } })
    local p = state.get_plugins()["neovim-tips"]
    p.dir = root -- loader sets this to the install path before config runs
    p.config({ path = root, spec = p }, p.opts)

    assert.same({ daily_tip = 0 }, _G.NT_OPTS)
    package.preload["neovim_tips"] = nil
    _G.NT_OPTS = nil
  end)
end)

describe("pack.state enabled=false vs invalid spec (4.x)", function()
  it("does not warn 'missing url' for an intentionally disabled spec", function()
    local warned = false
    local orig = vim.notify
    vim.notify = function(msg)
      if tostring(msg):find("missing url", 1, true) then
        warned = true
      end
    end
    state.add_plugin({ "u/foo", enabled = false }, {})
    vim.notify = orig
    assert.is_false(warned)
  end)

  it("still warns for a genuinely invalid spec with no url", function()
    local warned = false
    local orig = vim.notify
    vim.notify = function(msg)
      if tostring(msg):find("missing url", 1, true) then
        warned = true
      end
    end
    state.add_plugin({ opts = {} }, {})
    vim.notify = orig
    assert.is_true(warned)
  end)
end)

describe("pack.loader deterministic eager order (4.x)", function()
  it("loads equal-priority eager plugins in a stable (name) order", function()
    fake_plugin("alpha")
    fake_plugin("mu")
    fake_plugin("zeta")
    _G.PACK_ORDER = {}
    state.init({ plugins = { { "u/zeta" }, { "u/mu" }, { "u/alpha" } } })
    -- Enqueue in a deliberately non-alphabetical order.
    loader.load_fn({ spec = { name = "zeta" }, path = "/x/zeta" })
    loader.load_fn({ spec = { name = "mu" }, path = "/x/mu" })
    loader.load_fn({ spec = { name = "alpha" }, path = "/x/alpha" })
    loader.flush_pending()
    assert.same({ "alpha", "mu", "zeta" }, _G.PACK_ORDER)
    _G.PACK_ORDER = nil
  end)
end)

describe("pack.loader force-load tears down lazy triggers (4.x)", function()
  it("removes a lazy plugin's trigger command when it is force-loaded", function()
    fake_plugin("lazydep")
    state.init({ plugins = { { "u/lazydep", lazy = true, cmd = "LazyDepCmd" } } })
    local p = state.get_plugins()["lazydep"]
    loader.setup_triggers(p)
    assert.is_not_nil(vim.api.nvim_get_commands({})["LazyDepCmd"])

    loader.load("lazydep")
    assert.is_nil(
      vim.api.nvim_get_commands({})["LazyDepCmd"],
      "force-loading must tear down the leftover trigger command"
    )
  end)
end)

describe("pack.loader keys entry without lhs (4.x)", function()
  it("skips a keys entry that has no lhs instead of erroring", function()
    state.init({ plugins = { { "u/keyplug", lazy = true, keys = { { mode = "n" } } } } })
    local p = state.get_plugins()["keyplug"]
    local ok = pcall(loader.setup_triggers, p)
    assert.is_true(ok, "a malformed keys entry must not throw")
    loader.remove_triggers(p)
  end)
end)

describe("pack.loader cond single evaluation (4.x)", function()
  it("evaluates an eager plugin's cond once during flush", function()
    fake_plugin("condplug")
    local count = 0
    state.init({ plugins = { { "u/condplug", cond = function()
      count = count + 1
      return true
    end } } })
    loader.load_fn({ spec = { name = "condplug" }, path = "/x/condplug" })
    loader.flush_pending()
    assert.equals(1, count, "cond must not be evaluated twice (flush + load)")
  end)
end)

describe("pack.persist atomic write (4.x)", function()
  local tmp
  before_each(function()
    tmp = vim.fn.tempname() .. "-extra.json"
    persist._set_path_for_testing(tmp)
  end)
  after_each(function()
    if vim.fn.filereadable(tmp) == 1 then
      vim.fn.delete(tmp)
    end
    persist._set_path_for_testing(nil)
  end)

  it("round-trips the disabled set and leaves no temp file behind", function()
    persist.save({ ["foo.nvim"] = true })
    assert.is_true(persist.load()["foo.nvim"])
    -- No sibling temp artifact left over from the atomic write.
    assert.equals(0, vim.fn.filereadable(tmp .. ".tmp"))
  end)
end)

describe("pack.init Windows path normalization (load_plugins)", function()
  it("handles backslash path separators when matching lua module paths", function()
    local pack = require("pack")
    local orig_fn = vim.api.nvim_get_runtime_file
    vim.api.nvim_get_runtime_file = function(pattern, all)
      if pattern:find("lua/win_plugins") then
        return { "C:\\Users\\test\\.config\\nvim\\lua\\win_plugins\\editor.lua" }
      end
      return orig_fn(pattern, all)
    end

    package.preload["win_plugins.editor"] = function()
      return { "user/editor.nvim" }
    end

    local specs = pack._load_plugins("win_plugins")
    vim.api.nvim_get_runtime_file = orig_fn
    package.preload["win_plugins.editor"] = nil
    package.loaded["win_plugins.editor"] = nil

    assert.is_table(specs)
    assert.equals(1, #specs)
  end)
end)

describe("pack.init _install_and_load chunking and pcall guard", function()
  it("chunks large native specs into batches and handles native_pack.add errors gracefully", function()
    local pack = require("pack")
    local added_chunks = {}
    local orig_native = pack.native_pack

    pack.native_pack = {
      add = function(specs, opts)
        table.insert(added_chunks, #specs)
        if #added_chunks == 2 then
          error("Simulated lock_repair git error")
        end
      end
    }

    local mock_specs = {}
    for i = 1, 25 do
      table.insert(mock_specs, { name = "plugin_" .. i, src = "http://example.com/" .. i })
    end

    local ok = pcall(pack._install_and_load, mock_specs, false)
    pack.native_pack = orig_native

    assert.is_true(ok, "_install_and_load must not raise an unhandled exception")
    assert.same({ 10, 10, 5 }, added_chunks, "must chunk 25 specs into batches of 10, 10, 5")
  end)

  it("flips a not-yet-present plugin to 'installing' before the async native add resolves", function()
    local pack = require("pack")
    state.init({ plugins = { { "u/instplug" } } })
    local p = state.get_plugins()["instplug"]
    assert.equals("missing", p.status, "an uninstalled plugin starts in 'missing'")

    local orig_native = pack.native_pack
    -- Mock native add as a no-op: it never invokes load_fn, so the only status
    -- transition under test is the pre-add flip to "installing".
    pack.native_pack = { add = function() end }

    local ok = pcall(pack._install_and_load, { { name = p.name, src = p.url } }, false)

    pack.native_pack = orig_native
    assert.is_true(ok)
    assert.equals("installing", state.get_plugins()["instplug"].status)
  end)

  it("retries without a version constraint when native reports no tagged releases", function()
    local pack = require("pack")
    -- lazy=true: load_fn still runs (recording status/dir), but flush_pending
    -- only wires up triggers for it instead of eager-packadd-ing a path that
    -- doesn't really exist on disk -- keeping this test about the version
    -- fallback, not about a real plugin load succeeding.
    state.init({ plugins = { { "u/releaseless", version = "*", lazy = true } } })
    local p = state.get_plugins()["releaseless"]

    local add_calls = {}
    local orig_native = pack.native_pack
    pack.native_pack = {
      add = function(specs, opts)
        table.insert(add_calls, vim.deepcopy(specs))
        if specs[1].version ~= nil then
          error(
            "vim.pack:\n\n`releaseless`:\n"
              .. ".../pack.lua:652: No versions fit constraint. Relax it or switch to branch. Available:\n"
              .. "Versions: \nBranches: main"
          )
        end
        if opts and opts.load then
          opts.load({ spec = specs[1], path = "/tmp/releaseless" })
        end
      end,
    }

    local warned = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.WARN then
        table.insert(warned, tostring(msg))
      end
    end

    local ns = state.to_native_spec(p)
    local ok = pcall(pack._install_and_load, { ns }, false)

    vim.notify = orig_notify
    pack.native_pack = orig_native

    assert.is_true(ok)
    assert.equals(2, #add_calls, "first call carries the version constraint, the retry drops it")
    assert.is_not_nil(add_calls[1][1].version, "the first attempt still tries the requested version")
    assert.is_nil(add_calls[2][1].version, "the retry must drop the version constraint")
    assert.is_true(#warned > 0, "the fallback must be reported")
    assert.equals("installed", state.get_plugins()["releaseless"].status, "the retry must still install the plugin")
  end)

  it("does not retry (and reports normally) for an unrelated native_pack.add error", function()
    local pack = require("pack")
    state.init({ plugins = { { "u/unrelatederr", version = "*" } } })
    local p = state.get_plugins()["unrelatederr"]

    local add_calls = 0
    local orig_native = pack.native_pack
    pack.native_pack = {
      add = function(specs)
        add_calls = add_calls + 1
        error("some unrelated network failure")
      end,
    }

    local warned = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.WARN then
        table.insert(warned, tostring(msg))
      end
    end

    local ns = state.to_native_spec(p)
    local ok = pcall(pack._install_and_load, { ns }, false)

    vim.notify = orig_notify
    pack.native_pack = orig_native

    assert.is_true(ok)
    assert.equals(1, add_calls, "an unrelated error must not trigger the version-fallback retry")
    assert.is_true(#warned > 0, "the original failure must still be reported")
    assert.equals("error", state.get_plugins()["unrelatederr"].status)
  end)

  it("only strips the version constraint of the actual offending spec in a multi-spec batch", function()
    local pack = require("pack")
    -- Both plugins are already "installed" (dir present) so they route through
    -- the multi-spec installed_specs bulk-add path, not the single-spec
    -- missing-plugin path -- that's the path where the whole batch fails
    -- because of ONE spec, and only that spec's pin may be dropped.
    state.init({
      plugins = {
        { "u/goodpin", version = "*" },
        { "u/badpin", version = "*" },
      },
    })
    local good = state.get_plugins()["goodpin"]
    local bad = state.get_plugins()["badpin"]
    good.dir = vim.fn.tempname()
    bad.dir = vim.fn.tempname()
    vim.fn.mkdir(good.dir, "p")
    vim.fn.mkdir(bad.dir, "p")

    local NO_VERSIONS_ERR = "vim.pack:\n\n`badpin`:\n"
      .. ".../pack.lua:652: No versions fit constraint. Relax it or switch to branch. Available:\n"
      .. "Versions: \nBranches: main"

    local add_calls = {}
    local orig_native = pack.native_pack
    pack.native_pack = {
      add = function(specs)
        table.insert(add_calls, vim.deepcopy(specs))
        for _, s in ipairs(specs) do
          if s.name == "badpin" and s.version ~= nil then
            error(NO_VERSIONS_ERR)
          end
        end
      end,
    }

    local ns_good = state.to_native_spec(good)
    local ns_bad = state.to_native_spec(bad)
    local ok = pcall(pack._install_and_load, { ns_good, ns_bad }, false)

    pack.native_pack = orig_native
    assert.is_true(ok)

    assert.is_true(#add_calls >= 2, "the failing batch must be retried per-spec")
    assert.equals(2, #add_calls[1], "the first attempt is still the whole batch")

    -- table.insert would silently drop a nil entry, so track presence/absence
    -- of a version directly instead of collecting the (possibly-nil) values.
    local good_saw_nil_version, bad_had_nil_version = false, false
    for i = 2, #add_calls do
      for _, s in ipairs(add_calls[i]) do
        if s.name == "goodpin" and s.version == nil then
          good_saw_nil_version = true
        elseif s.name == "badpin" and s.version == nil then
          bad_had_nil_version = true
        end
      end
    end

    assert.is_false(good_saw_nil_version, "goodpin's valid version pin must never be dropped just because badpin failed")
    assert.is_true(bad_had_nil_version, "badpin must eventually be retried with its version constraint dropped")
  end)
end)

describe("pack.setup version gate (<0.12, no native vim.pack)", function()
  local pack = require("pack")
  local orig_vim_pack, orig_real_native, orig_native

  before_each(function()
    orig_vim_pack = vim.pack
    orig_real_native = pack._real_native
    orig_native = pack.native_pack
    pack._real_native = nil
    state.init({ plugins = {} })
  end)

  after_each(function()
    vim.pack = orig_vim_pack
    pack._real_native = orig_real_native
    pack.native_pack = orig_native
  end)

  it("warns and no-ops when native vim.pack.add is unavailable", function()
    -- Simulate an older Neovim: vim.pack exists but has no .add (or is absent).
    vim.pack = {} -- no .add

    local warned = false
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.ERROR and type(msg) == "string" and msg:find("0.12") then
        warned = true
      end
    end

    local ok = pcall(pack.setup, { plugins = { "user/should_not_register.nvim" } })

    vim.notify = orig_notify
    assert.is_true(ok, "setup must not throw on an unsupported Neovim")
    assert.is_true(warned, "setup must warn about the 0.12 requirement")
    -- Early return: no wrapper installed, no plugin registered.
    assert.is_nil(rawget(vim.pack, "__pack_wrapper"), "no wrapper must be installed")
    assert.is_nil(state.get_plugins()["should_not_register.nvim"], "no plugin should be registered")
  end)
end)
