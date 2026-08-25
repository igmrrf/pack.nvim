local loader = require("pack.loader")

describe("pack.loader triggers", function()
  -- maparg() only sees buffer-local maps of the *current* buffer, and a string
  -- rhs surfaces under .rhs rather than .callback. Scope + normalize here.
  local function buf_map(lhs, bufnr, mode)
    return vim.api.nvim_buf_call(bufnr, function()
      local m = vim.fn.maparg(lhs, mode or "n", false, true)
      if m and (m.callback or (m.rhs and m.rhs ~= "")) then
        return m
      end
      return nil
    end)
  end

  local function make_plugin(overrides)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local p = {
      name = "fixture.nvim",
      dir = dir,
      lazy = true,
      status = "installed",
    }
    return vim.tbl_extend("force", p, overrides or {})
  end

  it("registers a user command for a cmd trigger", function()
    local p = make_plugin({ cmd = "FixtureCmd" })
    loader.setup_triggers(p)
    local commands = vim.api.nvim_get_commands({})
    assert.is_not_nil(commands["FixtureCmd"])
    loader.remove_triggers(p)
  end)

  it("registers a FileType autocmd under a per-plugin augroup for a ft trigger", function()
    local p = make_plugin({ ft = "fixturefiletype" })
    loader.setup_triggers(p)
    local autocmds = vim.api.nvim_get_autocmds({ group = "pack_trigger_fixture.nvim" })
    assert.is_true(#autocmds > 0)
    loader.remove_triggers(p)
  end)

  it("calling setup_triggers twice does not error", function()
    local p = make_plugin({ cmd = "FixtureCmdTwice" })
    loader.setup_triggers(p)
    local ok = pcall(loader.setup_triggers, p)
    assert.is_true(ok)
    loader.remove_triggers(p)
  end)

  it("remove_triggers deletes the command and the augroup", function()
    local p = make_plugin({ cmd = "FixtureCmdRemove", event = "VimResized" })
    loader.setup_triggers(p)
    loader.remove_triggers(p)

    local commands = vim.api.nvim_get_commands({})
    assert.is_nil(commands["FixtureCmdRemove"])

    local ok = pcall(vim.api.nvim_get_autocmds, { group = "pack_trigger_fixture.nvim" })
    assert.is_false(ok)
  end)

  it("enable() does not error for a non-lazy installed plugin", function()
    local p = make_plugin({ lazy = false, status = "installed" })
    local ok = pcall(loader.enable, p)
    assert.is_true(ok)
  end)

  it("enable() is a safe no-op for an already-loaded plugin (nothing was torn down for it)", function()
    local p = make_plugin({ lazy = false, status = "loaded", keys = { { "<leader>ff", "<cmd>echo 'ff'<CR>" } } })
    vim.keymap.set("n", "<leader>ff", "<cmd>echo 'ff'<CR>")
    assert.is_true(vim.fn.maparg("<leader>ff", "n") ~= "")

    local ok = pcall(loader.enable, p)
    assert.is_true(ok)
    -- state/keymap untouched: enable() must not attempt to restore or
    -- otherwise modify an already-loaded plugin's live keymaps.
    assert.equals("loaded", p.status)
    assert.is_true(vim.fn.maparg("<leader>ff", "n") ~= "")

    pcall(vim.keymap.del, "n", "<leader>ff")
  end)

  it("remove_triggers respects command ownership after collision", function()
    -- Regression test: Plugin A registers :Foo, Plugin B later overwrites it.
    -- Removing A should NOT delete :Foo because B now owns it.
    local p_a = make_plugin({ name = "plugin_a.nvim", cmd = "CollisionCmd" })
    local p_b = make_plugin({ name = "plugin_b.nvim", cmd = "CollisionCmd" })

    -- A registers the command
    loader.setup_triggers(p_a)
    local commands = vim.api.nvim_get_commands({})
    assert.is_not_nil(commands["CollisionCmd"])

    -- B overwrites it
    loader.setup_triggers(p_b)
    commands = vim.api.nvim_get_commands({})
    assert.is_not_nil(commands["CollisionCmd"])

    -- Remove A's triggers - should NOT delete the command since B owns it
    loader.remove_triggers(p_a)
    commands = vim.api.nvim_get_commands({})
    assert.is_not_nil(commands["CollisionCmd"], "Command should still exist and belong to B")

    -- Clean up B's command
    loader.remove_triggers(p_b)
    commands = vim.api.nvim_get_commands({})
    assert.is_nil(commands["CollisionCmd"])
  end)

  it("does not pass non-keymap fields (e.g. a lazy.nvim-style per-key `ft`) through to vim.keymap.set", function()
    local p = make_plugin({ keys = { { "<F20>", ":Noop<CR>", ft = "markdown", desc = "noop" } } })
    local ok, err = pcall(loader.setup_triggers, p)
    assert.is_true(ok, "a keys entry with a non-keymap field must not error: " .. tostring(err))

    -- Scoping comes from the PLUGIN-level ft only; an entry-level field is
    -- dropped (not forwarded to vim.keymap.set) and the map binds globally.
    local map = vim.fn.maparg("<F20>", "n", false, true)
    assert.equals("noop", map.desc)
    loader.remove_triggers(p)
  end)

  it("keys on a spec without ft are bound globally (no accidental scoping)", function()
    local state = require("pack.state")
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local config = {
      plugins = {
        {
          "user/globkey.nvim",
          dir = dir,
          lazy = true,
          keys = { { "<F25>", ":EchoGlob<CR>" } },
        },
      },
    }
    state.init(config)
    local p = state.get_plugins()["globkey.nvim"]
    loader.setup_triggers(p)

    assert.is_not_nil(buf_map("<F25>", vim.api.nvim_get_current_buf()), "no ft means the placeholder stays global")
    loader.remove_triggers(p)
    assert.is_nil(buf_map("<F25>", vim.api.nvim_get_current_buf()))
  end)

  it("with a plugin-level ft, keys exist only in matching buffers before loading", function()
    local p = make_plugin({
      name = "ftgate.nvim",
      ft = { "python", "rust" },
      status = nil,
      keys = {
        { "<F21>", ":NoopFt<CR>", desc = "gated" },
        { "<F22>", mode = "x" }, -- bare key also gated
      },
    })
    loader.setup_triggers(p)

    -- No global placeholders at all (checked from a non-matching buffer).
    local plain_buf = vim.api.nvim_get_current_buf()
    for _, lhs in ipairs({ "<F21>", "<F22>" }) do
      assert.is_nil(buf_map(lhs, plain_buf), lhs .. " must not be bound in normal mode")
      assert.is_nil(buf_map(lhs, plain_buf, "x"), lhs .. " must not be bound in visual mode")
    end

    -- A matching buffer gets buffer-local placeholders.
    local py_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(py_buf)
    vim.bo[py_buf].filetype = "python"
    local m = buf_map("<F21>", py_buf)
    assert.is_not_nil(m, "matching ft must get the placeholder")
    assert.equals("gated", m.desc)
    assert.truthy(m.buffer, "placeholder must be buffer-local")
    assert.is_not_nil(buf_map("<F22>", py_buf, "x"), "bare key must be gated too")

    -- An unrelated filetype never sees either key.
    local lua_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(lua_buf)
    vim.bo[lua_buf].filetype = "lua"
    assert.is_nil(buf_map("<F21>", lua_buf))
    assert.is_nil(buf_map("<F22>", lua_buf, "x"))

    loader.remove_triggers(p)
    assert.is_nil(buf_map("<F21>", py_buf), "remove_triggers must drop the gated maps")
  end)

  it("pressing an ft-gated lazy key loads the plugin and the real mapping stays ft-scoped", function()
    local state = require("pack.state")
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local config = {
      plugins = {
        {
          "user/ftkey.nvim",
          dir = dir,
          lazy = true,
          ft = "python",
          keys = { { "<F27>", function() _G.FTKEY_FIRED = true end } },
        },
      },
    }
    state.init(config)
    local p = state.get_plugins()["ftkey.nvim"]
    loader.setup_triggers(p)

    -- Non-matching filetype never sees the key, before OR after loading.
    local lua_buf = vim.api.nvim_create_buf(true, false)
    vim.bo[lua_buf].filetype = "lua"
    vim.api.nvim_set_current_buf(lua_buf)
    assert.is_nil(buf_map("<F27>", lua_buf), "non-matching ft must have no placeholder")

    -- Matching buffer gets the buffer-local placeholder via FileType/seeding.
    local py_buf = vim.api.nvim_create_buf(true, false)
    vim.bo[py_buf].filetype = "python"
    vim.api.nvim_set_current_buf(py_buf)
    local placeholder = buf_map("<F27>", py_buf)
    assert.is_not_nil(placeholder, "matching ft must get the lazy-load placeholder")
    assert.is_not_nil(placeholder.callback)

    placeholder.callback()
    assert.equals("loaded", p.status, "pressing the key in a matching buffer must load the plugin")
    _G.FTKEY_FIRED = nil

    -- Real mapping is now buffer-local to python buffers only.
    local real_map = buf_map("<F27>", py_buf)
    assert.is_not_nil(real_map.callback, "real mapping must be rebound in the python buffer")
    real_map.callback()
    assert.is_true(_G.FTKEY_FIRED)
    _G.FTKEY_FIRED = nil

    assert.is_nil(buf_map("<F27>", lua_buf), "lua buffer must still not see the mapping")

    -- Future python buffers receive the real mapping through the FileType watcher.
    local py2 = vim.api.nvim_create_buf(true, false)
    vim.bo[py2].filetype = "python"
    assert.is_not_nil(buf_map("<F27>", py2).callback, "future matching buffers must inherit the real mapping")

    loader.remove_triggers(p)
    assert.is_nil(buf_map("<F27>", py_buf), "remove_triggers must drop buffer-local real mappings")
  end)

  it("an ft-gated key on a plugin loaded via another trigger binds only in matching buffers", function()
    local state = require("pack.state")
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local config = {
      plugins = {
        {
          "user/ftevent.nvim",
          dir = dir,
          lazy = true,
          event = "VimResized",
          ft = { "go", "rust" },
          keys = { { "<F26>", ":EchoHi<CR>" } },
        },
      },
    }
    state.init(config)
    local p = state.get_plugins()["ftevent.nvim"]
    loader.setup_triggers(p)

    -- Plugin loads without its key ever being pressed.
    loader.load("ftevent.nvim")
    assert.equals("loaded", p.status)

    local go_buf = vim.api.nvim_create_buf(true, false)
    vim.bo[go_buf].filetype = "go"
    local go_map = buf_map("<F26>", go_buf)
    assert.is_not_nil(go_map, "first ft in list must get the real mapping post-load")
    assert.truthy(go_map.buffer, "real mapping must be buffer-local")

    local rust_buf = vim.api.nvim_create_buf(true, false)
    vim.bo[rust_buf].filetype = "rust"
    assert.is_not_nil(buf_map("<F26>", rust_buf), "second ft in list must also match")

    local lua_buf = vim.api.nvim_create_buf(true, false)
    vim.bo[lua_buf].filetype = "lua"
    assert.is_nil(buf_map("<F26>", lua_buf), "unlisted ft must stay unmapped")

    -- Pre-existing matching buffers get seeded immediately at rebind time too.
    local go2 = vim.api.nvim_create_buf(true, false)
    vim.bo[go2].filetype = "go"
    local go2_map = buf_map("<F26>", go2)
    assert.is_not_nil(go2_map, "existing go buffer must be seeded via FileType watcher")
    assert.equals(":EchoHi<CR>", go2_map.rhs)

    loader.remove_triggers(p)
    assert.is_nil(buf_map("<F26>", go_buf), "remove_triggers must drop ft-scoped real mappings")
  end)

  it("restores a lazy plugin's real key mapping after it loads via a non-key trigger (event/cmd/dependency)", function()
    local state = require("pack.state")
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local config = {
      plugins = {
        {
          "user/keyload",
          dir = dir,
          lazy = true,
          event = "VimResized",
          keys = { { "<F19>", function() _G.KEYLOAD_FIRED = true end } },
        },
      },
    }
    state.init(config)
    local p = state.get_plugins()["keyload"]
    -- Wires the event autocmd AND the <F19> lazy-load placeholder keymap.
    loader.setup_triggers(p)

    -- Something other than the key itself (the event, a :cmd, a dependency
    -- force-load, require()) loads the plugin before <F19> is ever pressed.
    loader.load("keyload")

    local map = vim.fn.maparg("<F19>", "n", false, true)
    assert.is_not_nil(
      map.callback,
      "the plugin's real key mapping must be (re)bound once it has loaded, however it loaded"
    )
    map.callback()
    assert.is_true(_G.KEYLOAD_FIRED)
    _G.KEYLOAD_FIRED = nil
    pcall(vim.keymap.del, "n", "<F19>")
  end)

  it("prevents infinite recursion when a plugin require()s itself during loading", function()
    local state = require("pack.state")
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local config = {
      plugins = {
        { "user/recursive.nvim", lazy = true, cmd = "RecCmd", dir = dir },
      },
    }
    state.init(config)
    local p = state.get_plugins()["recursive.nvim"]
    p.status = "installed"

    -- Simulate require() interceptor calling loader.load() while loading is in progress
    p.config = function()
      loader.load("recursive.nvim")
    end

    local ok = pcall(loader.load, "recursive.nvim")
    assert.is_true(ok)
    assert.equals("loaded", p.status)
  end)

  it("does not warn when a lazy plugin with a bare `keys` entry (no rhs) loads", function()
    local state = require("pack.state")
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local config = {
      plugins = {
        -- Bare key: plugin owns the real mapping, this only triggers lazy-load.
        { "user/barekey.nvim", dir = dir, lazy = true, keys = { "<F30>" } },
      },
    }
    state.init(config)
    local p = state.get_plugins()["barekey.nvim"]

    local warned = false
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.WARN and type(msg) == "string" and msg:find("nothing to bind") then
        warned = true
      end
    end

    loader.setup_triggers(p)
    loader.load("barekey.nvim")

    vim.notify = orig_notify
    assert.is_false(warned, "post-load rebind of a bare lazy key must not warn 'nothing to bind'")
    pcall(vim.keymap.del, "n", "<F30>")
  end)

  it("still warns for a non-lazy plugin declaring a bare `keys` entry (genuine no-op)", function()
    local p = make_plugin({ status = "loaded", lazy = false, keys = { "<F29>" } })
    local warned = false
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.WARN and type(msg) == "string" and msg:find("nothing to bind") then
        warned = true
      end
    end
    loader.setup_triggers(p)
    vim.notify = orig_notify
    assert.is_true(warned, "a non-lazy bare key is a real misconfig and should warn")
  end)

  it("does not mark the lazy-load placeholder as an <expr> mapping", function()
    local p = make_plugin({ keys = { { "<F31>", function() return "x" end, expr = true } } })
    loader.setup_triggers(p)
    local map = vim.fn.maparg("<F31>", "n", false, true)
    assert.equals(0, map.expr, "the lazy placeholder must not be expr (feedkeys under expr hits textlock)")
    loader.remove_triggers(p)
    pcall(vim.keymap.del, "n", "<F31>")
  end)

  it("replays the returned string of an expr function rhs on initial trigger", function()
    local state = require("pack.state")
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local fn_called = false
    local config = {
      plugins = {
        {
          "user/exprfn.nvim",
          dir = dir,
          lazy = true,
          keys = {
            {
              "<F32>",
              function()
                fn_called = true
                return "ihello<Esc>"
              end,
              expr = true,
            },
          },
        },
      },
    }
    state.init(config)
    local p = state.get_plugins()["exprfn.nvim"]
    loader.setup_triggers(p)

    local map = vim.fn.maparg("<F32>", "n", false, true)
    assert.is_not_nil(map.callback)
    map.callback()

    assert.is_true(fn_called, "expr function rhs must be invoked on initial trigger")
    assert.equals("loaded", p.status, "plugin must be loaded")
    pcall(vim.keymap.del, "n", "<F32>")
  end)
end)

