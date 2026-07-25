-- ============================================================================
-- MIGRATION GUIDE: lazy.nvim -> pack.nvim
-- ============================================================================
-- pack.nvim is intentionally designed to feel very familiar to lazy.nvim users,
-- making migration straightforward. The primary differences revolve around the
-- fact that pack.nvim uses Neovim 0.12+ native package management underneath.
--
-- Key Differences:
-- 1. Setup call: require("pack").setup({ plugins = { ... } }) instead of require("lazy").setup(...)
-- 2. No `dir` or `url` fields: Use `url` or `src` for full urls. For local plugins,
--    use `dir = "~/path"`.
-- 3. Lockfile: Handled natively by Neovim in `stdpath('data')/site/pack/core/pack.lock`.
-- 4. No automatic `mapleader` handling inside setup; set it BEFORE setup().
--
-- Example Conversion:

-- ==========================================
-- BEFORE: lazy.nvim
-- ==========================================
-- local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
-- if not vim.loop.fs_stat(lazypath) then
--   vim.fn.system({ "git", "clone", "--filter=blob:none", "https://github.com/folke/lazy.nvim.git", "--branch=stable", lazypath })
-- end
-- vim.opt.rtp:prepend(lazypath)
-- 
-- vim.g.mapleader = " "
-- require("lazy").setup({
--   { "folke/which-key.nvim", opts = {} },
--   { "nvim-treesitter/nvim-treesitter", build = ":TSUpdate" },
--   { import = "plugins" },
-- })

-- ==========================================
-- AFTER: pack.nvim
-- ==========================================
-- 1. Set leader key first
vim.g.mapleader = " "

-- 2. Bootstrap pack.nvim natively (Neovim 0.12+)
vim.pack.add({ { src = "https://github.com/igmrrf/pack.nvim", version = "main" } })
vim.cmd.packadd("pack.nvim")

-- 3. Setup
require("pack").setup({
  plugins = {
    -- IMPORTANT: Keep pack.nvim in your specs so native vim.pack manages its updates
    { "igmrrf/pack.nvim", branch = "main" },
    
    -- Specs remain nearly identical
    { "folke/which-key.nvim", opts = {} },
    
    -- Build hooks work the same way
    { "nvim-treesitter/nvim-treesitter", build = ":TSUpdate" },
    
    -- Modular config importing works exactly the same
    { import = "plugins" },
  }
})
