local pack = require("pack")
local state = require("pack.state")
local loader = require("pack.loader")
local persist = require("pack.persist")

-- A stand-in for native vim.pack. add() synchronously invokes the load callback
-- for each spec (like native does after cloning) so our loader runs.
local function make_fake()
  local fake = { added = {}, updated = {}, deleted = {}, get_result = {} }
  function fake.add(specs, opts)
    for _, s in ipairs(specs) do
      table.insert(fake.added, s)
      if opts and opts.load then
        opts.load({ spec = s, path = "/fake/" .. s.name })
      end
    end
  end
  function fake.update(names, opts)
    table.insert(fake.updated, { names = names, opts = opts })
  end
  function fake.del(names)
    table.insert(fake.deleted, names)
  end
  function fake.get()
    return fake.get_result
  end
  return fake
end

describe("pack.init native delegation", function()
  local tmp_path, fake
  local orig_load, orig_setup_triggers, orig_vim_pack
  local loaded, triggered

  before_each(function()
    tmp_path = vim.fn.tempname() .. "-pack-disabled.json"
    persist._set_path_for_testing(tmp_path)

    loaded, triggered = {}, {}
    orig_load = loader.load
    orig_setup_triggers = loader.setup_triggers
    loader.load = function(name) table.insert(loaded, name) end
    loader.setup_triggers = function(p) table.insert(triggered, p.name) end

    orig_vim_pack = vim.pack
    fake = make_fake()
    vim.pack = fake
  end)

  after_each(function()
    loader.load = orig_load
    loader.setup_triggers = orig_setup_triggers
    vim.pack = orig_vim_pack
    if vim.fn.filereadable(tmp_path) == 1 then vim.fn.delete(tmp_path) end
    persist._set_path_for_testing(nil)
  end)

  local function do_setup(plugins)
    pack.setup({ install_path = vim.fn.tempname() .. "-pack-install", plugins = plugins })
  end

  it("installs configured plugins through native vim.pack.add", function()
    do_setup({ "user/foo.nvim", "user/bar.nvim" })
    assert.equals(2, #fake.added)
    local names = { fake.added[1].name, fake.added[2].name }
    table.sort(names)
    assert.same({ "bar.nvim", "foo.nvim" }, names)
    -- src is the resolved clone URL, not the shorthand
    assert.matches("^https://github.com/user/", fake.added[1].src)
  end)

  it("loads eager plugins and triggers lazy ones after native add", function()
    do_setup({
      { "user/eager.nvim" },
      { "user/lazy.nvim", lazy = true, cmd = "LazyCmd" },
    })
    assert.same({ "eager.nvim" }, loaded)
    assert.same({ "lazy.nvim" }, triggered)
  end)

  it("does not send disabled plugins to native", function()
    -- Pre-mark bar disabled via the persisted set, then setup.
    persist.set_disabled("bar.nvim", true)
    do_setup({ "user/foo.nvim", "user/bar.nvim" })
    assert.equals(1, #fake.added)
    assert.equals("foo.nvim", fake.added[1].name)
  end)

  it("carries the resolved version pin into the native spec", function()
    do_setup({ { "user/foo.nvim", tag = "v1.2.3" } })
    assert.equals("v1.2.3", fake.added[1].version)
  end)

  it("preserves pack.nvim metadata on native-style (src=) specs", function()
    do_setup({
      { src = "https://github.com/user/eager.nvim", name = "eager.nvim" },
      { src = "https://github.com/user/lazy.nvim", name = "lazy.nvim", lazy = true, cmd = "LazyCmd" },
    })
    -- src-style lazy spec keeps its lazy trigger (not eagerly loaded)
    assert.same({ "eager.nvim" }, loaded)
    assert.same({ "lazy.nvim" }, triggered)

    local p = state.get_plugins()["lazy.nvim"]
    assert.is_true(p.lazy)
    assert.equals("LazyCmd", p.cmd)
    assert.equals("https://github.com/user/lazy.nvim", p.url)
    -- native spec round-trips src correctly
    local added = {}
    for _, s in ipairs(fake.added) do added[s.name] = s end
    assert.equals("https://github.com/user/lazy.nvim", added["lazy.nvim"].src)
  end)

  it("vim.pack.add dynamically installs a new plugin via native", function()
    do_setup({ "user/foo.nvim" })
    local before = #fake.added
    vim.pack.add({ "user/new.nvim" })
    assert.equals(before + 1, #fake.added)
    assert.equals("new.nvim", fake.added[#fake.added].name)
  end)

  it("vim.pack.del removes state and delegates to native del", function()
    do_setup({ "user/foo.nvim" })
    vim.pack.del("foo.nvim")
    assert.is_nil(state.get_plugins()["foo.nvim"])
    assert.equals(1, #fake.deleted)
    assert.same({ "foo.nvim" }, fake.deleted[1])
  end)

  it("vim.pack.update delegates to native update", function()
    do_setup({ "user/foo.nvim" })
    vim.pack.update()
    assert.equals(1, #fake.updated)
  end)

  it(":Pack sync delegates to native update-all", function()
    do_setup({ "user/foo.nvim" })
    vim.cmd("Pack sync")
    assert.is_true(#fake.updated >= 1)
    assert.is_nil(fake.updated[#fake.updated].names)
  end)

  it(":Pack restore delegates to native lockfile update", function()
    do_setup({ "user/foo.nvim" })
    vim.cmd("Pack restore")
    local last = fake.updated[#fake.updated]
    assert.equals("lockfile", last.opts.target)
  end)

  it("vim.pack.get falls through to native via metatable", function()
    do_setup({ "user/foo.nvim" })
    fake.get_result = { "sentinel" }
    assert.same({ "sentinel" }, vim.pack.get())
  end)

  it("reconcile_from_native updates dir/rev/status from native get()", function()
    do_setup({ "user/foo.nvim" })
    local p = state.get_plugins()["foo.nvim"]
    p.status = "missing"
    fake.get_result = {
      { spec = { name = "foo.nvim" }, path = "/real/foo.nvim", rev = "cafebabe" },
    }
    state.reconcile_from_native(require("pack").native_pack)
    assert.equals("/real/foo.nvim", p.dir)
    assert.equals("cafebabe", p.rev)
    assert.equals("installed", p.status)
  end)
end)
