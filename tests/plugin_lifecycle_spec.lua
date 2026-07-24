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
