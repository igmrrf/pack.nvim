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
end)
