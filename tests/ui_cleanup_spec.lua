local ui = require("pack.ui")

describe("pack.ui popup cleanup (2.6)", function()
  it("removes the popup resize autocmd when the popup window closes", function()
    ui.show_help()
    local win = vim.api.nvim_get_current_win()
    local b = vim.api.nvim_win_get_buf(win)
    local grp = "pack_popup_" .. b

    assert.is_true(pcall(vim.api.nvim_get_autocmds, { group = grp }), "augroup exists while open")

    vim.api.nvim_win_close(win, true)
    vim.wait(500, function()
      return not pcall(vim.api.nvim_get_autocmds, { group = grp })
    end)
    assert.is_false(
      pcall(vim.api.nvim_get_autocmds, { group = grp }),
      "popup augroup must be deleted after the window closes"
    )
  end)

  it("tears down the dashboard resize/startup-focus augroups on close", function()
    local state = require("pack.state")
    local cfg = {
      plugins = { "user/foo.nvim" },
      ui = { border = "rounded", icons = { loaded = "*", not_loaded = "o", error = "x", sync = "~" } },
    }
    state.init(cfg)
    ui.open(cfg)

    assert.is_true(pcall(vim.api.nvim_get_autocmds, { group = "pack_ui_resize" }), "resize augroup exists while open")

    ui.close()

    assert.is_false(
      pcall(vim.api.nvim_get_autocmds, { group = "pack_ui_resize" }),
      "pack_ui_resize augroup must be deleted on ui.close()"
    )
    assert.is_false(
      pcall(vim.api.nvim_get_autocmds, { group = "pack_ui_startup_focus" }),
      "pack_ui_startup_focus augroup must be deleted on ui.close()"
    )
  end)
end)
