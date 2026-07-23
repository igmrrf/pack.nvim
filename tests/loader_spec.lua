local loader = require("packui.loader")

describe("packui.loader triggers", function()
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
    local autocmds = vim.api.nvim_get_autocmds({ group = "packui_trigger_fixture.nvim" })
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

    local ok = pcall(vim.api.nvim_get_autocmds, { group = "packui_trigger_fixture.nvim" })
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
end)
