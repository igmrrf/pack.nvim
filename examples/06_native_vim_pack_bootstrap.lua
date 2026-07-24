-- Bootstrap pack.nvim using Neovim 0.12+ native vim.pack.add
-- This delegates the initial cloning and installation entirely to Neovim.

-- 1. Tell Neovim to download and add pack.nvim to the package path.
-- By default, vim.pack.add installs into `~/.local/share/nvim/site/pack/core/opt/<plugin>`
vim.pack.add({ "https://github.com/igmrrf/pack.nvim" })

-- 2. Since vim.pack.add places the plugin in `opt/`, we must manually load it
vim.cmd("packadd pack.nvim")

-- 3. Setup pack.nvim and instruct it to manage plugins in the same directory vim.pack uses
require("pack").setup({
  -- Match the directory where vim.pack natively installs plugins
  install_path = vim.fn.stdpath("data") .. "/site/pack/core",
  
  plugins = {
    -- Important: If you list pack.nvim here, pack.nvim will manage its own updates going forward.
    -- DO NOT run `vim.pack.update()` on pack.nvim after this point, as it will conflict
    -- with `pack.nvim`'s own internal Git operations during `:Pack sync`.
    { "igmrrf/pack.nvim" },

    -- Add your other plugins here
    { "nvim-lua/plenary.nvim" },
  }
})
