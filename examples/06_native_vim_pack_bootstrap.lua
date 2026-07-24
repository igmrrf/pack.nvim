-- Bootstrap pack.nvim using Neovim 0.12+ native vim.pack.add
-- This delegates the initial cloning and installation entirely to Neovim.

-- 1. Tell Neovim to download and add pack.nvim to the package path.
-- By default, vim.pack.add installs into `~/.local/share/nvim/site/pack/core/opt/<plugin>`
vim.pack.add({ "https://github.com/igmrrf/pack.nvim" })

-- 2. Since vim.pack.add places the plugin in `opt/`, we must manually load it
vim.cmd("packadd pack.nvim")

-- 3. Setup pack.nvim. It delegates all git operations to native vim.pack, so
--    there is nothing to configure about the install location.
require("pack").setup({
  plugins = {
    -- Safe to list pack.nvim here: it has no internal git engine, so
    -- `:Pack sync` / `vim.pack.update()` update it via native vim.pack just
    -- like any other plugin -- no conflict.
    { "igmrrf/pack.nvim" },

    -- Add your other plugins here
    { "nvim-lua/plenary.nvim" },
  }
})
