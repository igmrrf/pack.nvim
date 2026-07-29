local pack = require("pack")
local state = require("pack.state")
local ui = require("pack.ui")
local helpers = require("tests.helpers")

describe("Pack user commands and subcommands", function()
  before_each(function()
    helpers.reset()
    pack.setup({
      plugins = {
        { "user/foo.nvim" },
        { "user/bar.nvim" },
      },
    })
  end)

  after_each(function()
    local wins = vim.api.nvim_list_wins()
    for i = 2, #wins do
      pcall(vim.api.nvim_win_close, wins[i], true)
    end
  end)

  it("runs :Pack to open dashboard float", function()
    vim.cmd("Pack")
    local buf = vim.api.nvim_get_current_buf()
    local ft = vim.bo[buf].filetype
    assert.equals("pack", ft)
  end)

  it("runs :Pack sync without throwing errors", function()
    local orig_update = require("pack.async").update_plugins
    local sync_called = false
    require("pack.async").update_plugins = function()
      sync_called = true
    end
    vim.cmd("Pack sync")
    require("pack.async").update_plugins = orig_update
  end)

  it("runs :Pack update and :Pack update <target>", function()
    local updated_names = nil
    local orig_native = pack.native_pack.update
    pack.native_pack.update = function(names)
      updated_names = names
    end

    vim.cmd("Pack update foo.nvim")
    assert.same({ "foo.nvim" }, updated_names)

    vim.cmd("Pack update")
    pack.native_pack.update = orig_native
  end)

  it("runs :Pack build and :Pack build <target>", function()
    local built = {}
    local orig_build = require("pack.async").run_build_hook
    require("pack.async").run_build_hook = function(p, done)
      table.insert(built, p.name)
      done()
    end

    vim.cmd("Pack build foo.nvim")
    assert.same({ "foo.nvim" }, built)

    built = {}
    vim.cmd("Pack build")
    assert.is_true(#built > 0)
    require("pack.async").run_build_hook = orig_build
  end)

  it("runs :Pack load <target>", function()
    local loaded_target = nil
    local orig_load = require("pack.loader").load
    require("pack.loader").load = function(name)
      loaded_target = name
    end

    vim.cmd("Pack load foo.nvim")
    assert.equals("foo.nvim", loaded_target)
    require("pack.loader").load = orig_load
  end)

  it("runs :Pack delete <target>", function()
    local deleted_name = nil
    local orig_del = vim.pack.del
    vim.pack.del = function(names)
      deleted_name = names[1]
    end

    vim.cmd("Pack delete foo.nvim")
    assert.equals("foo.nvim", deleted_name)
    vim.pack.del = orig_del
  end)

  it("runs :Pack clean", function()
    local orig_get = pack.native_pack.get
    pack.native_pack.get = function()
      return {}
    end
    vim.cmd("Pack clean")
    pack.native_pack.get = orig_get
  end)

  it("runs :Pack restore", function()
    local restore_called = false
    local orig_update = pack.native_pack.update
    pack.native_pack.update = function(names, opts)
      if opts and opts.target == "lockfile" then
        restore_called = true
      end
    end

    vim.cmd("Pack restore")
    assert.is_true(restore_called)
    pack.native_pack.update = orig_update
  end)

  it("runs :Pack repair", function()
    local lockfile = require("pack.lockfile")
    local orig_repair = lockfile.repair
    local repair_called = false
    lockfile.repair = function()
      repair_called = true
      return {}, nil
    end

    vim.cmd("Pack repair")
    assert.is_true(repair_called)
    lockfile.repair = orig_repair
  end)

  it("runs :Pack profile", function()
    vim.cmd("Pack profile")
    local buf = vim.api.nvim_get_current_buf()
    assert.equals("pack_profile", vim.bo[buf].filetype)
  end)

  it("runs :Pack diff", function()
    state.get_plugins()["foo.nvim"].behind = 2
    vim.cmd("Pack diff")
    local buf = vim.api.nvim_get_current_buf()
    assert.equals("pack_diff", vim.bo[buf].filetype)
  end)

  it("completes :Pack subcommands and targets", function()
    local cmd = vim.api.nvim_get_commands({})["Pack"]
    assert.is_not_nil(cmd)
    local complete_fn = cmd.complete

    -- Completion for subcommands
    local sub_matches = complete_fn("up", "Pack up", 7)
    assert.is_true(vim.tbl_contains(sub_matches, "update"))

    -- Completion for plugin target
    local plugin_matches = complete_fn("fo", "Pack update fo", 14)
    assert.is_true(vim.tbl_contains(plugin_matches, "foo.nvim"))
  end)

  it("supports config.ui.filter modes (default, function)", function()
    -- Default mode (vim.ui.input)
    pack.setup({ ui = { filter = "default" } })
    local ui_input_called = false
    local orig_ui_input = vim.ui.input
    vim.ui.input = function(opts, cb)
      ui_input_called = true
      cb("foo")
    end
    ui.open(pack.config)
    ui.filter()
    assert.is_true(ui_input_called)
    vim.ui.input = orig_ui_input

    -- Custom function mode
    local custom_called = false
    pack.setup({
      ui = {
        filter = function(opts, cb)
          custom_called = true
          cb("baz")
        end,
      },
    })
    ui.filter()
    assert.is_true(custom_called)
  end)
end)
