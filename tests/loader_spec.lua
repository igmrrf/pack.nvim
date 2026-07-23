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
end)
