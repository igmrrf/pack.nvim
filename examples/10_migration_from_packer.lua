-- ============================================================================
-- MIGRATION GUIDE: packer.nvim -> pack.nvim
-- ============================================================================
-- packer.nvim used an imperative `use` syntax and required running `:PackerSync`
-- to compile files. pack.nvim is declarative, requires no compilation step, 
-- and leverages Neovim 0.12+ native package management.
--
-- Key Differences:
-- 1. No `:PackerSync` or compilation step needed.
-- 2. `use` is replaced by table entries in the `plugins` list.
-- 3. `requires` is now `dependencies`.
-- 4. `run` is now `build`.
-- 5. `setup` is now `init` (runs before load).
-- 6. `config` remains `config` (runs after load).
--
-- Example Conversion:

-- ==========================================
-- BEFORE: packer.nvim
-- ==========================================
-- require('packer').startup(function(use)
--   use 'wbthomason/packer.nvim'
--   
--   use {
--     'nvim-telescope/telescope.nvim',
--     requires = { {'nvim-lua/plenary.nvim'} }
--   }
--   
--   use {
--     'nvim-treesitter/nvim-treesitter',
--     run = ':TSUpdate'
--   }
-- end)

-- ==========================================
-- AFTER: pack.nvim
-- ==========================================
vim.g.mapleader = " "
vim.pack.add({ { src = "https://github.com/igmrrf/pack.nvim", version = "main" } })
vim.cmd.packadd("pack.nvim")

require("pack").setup({
  plugins = {
    { "igmrrf/pack.nvim", branch = "main" },
    
    -- Nested table for dependencies
    {
      "nvim-telescope/telescope.nvim",
      dependencies = { "nvim-lua/plenary.nvim" }
    },
    
    -- `run` becomes `build`
    {
      "nvim-treesitter/nvim-treesitter",
      build = ":TSUpdate"
    }
  }
})
