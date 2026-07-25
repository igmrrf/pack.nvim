-- This example demonstrates how to split a large plugin configuration across
-- multiple files for better organization (similar to lazy.nvim).

-- ============================================================================
-- 1. Main entry point (e.g., ~/.config/nvim/init.lua)
-- ============================================================================

-- Bootstrap pack.nvim itself using the native package manager
vim.pack.add({ "https://github.com/igmrrf/pack.nvim" })
vim.cmd.packadd("pack.nvim")

-- Initialize pack.nvim
require("pack").setup({
  plugins = {
    -- Let pack.nvim manage itself
    { "igmrrf/pack.nvim" },

    -- By using `{ import = "plugins" }`, pack.nvim will automatically search
    -- for any `.lua` files located in `lua/plugins/**/*.lua` in your runtime
    -- path, and load the plugin specs returned by those files.
    { import = "plugins" },
  }
})

-- ============================================================================
-- 2. An imported plugin file (e.g., ~/.config/nvim/lua/plugins/tabscope.lua)
-- ============================================================================

-- IMPORTANT: Inside your modular plugin files, DO NOT wrap your configuration
-- in `vim.pack.add({ ... })`. Instead, simply `return` the plugin spec table.
-- pack.nvim will automatically discover it and process it.

return {
  "backdround/tabscope.nvim",
  lazy = true,
  enabled = false, -- If false, pack.nvim completely ignores this spec
  keys = {
    {
      "<leader>bd",
      function()
        require("tabscope").remove_tab_buffer()
      end,
      mode = { "n" },
      desc = "Delete tab buffer",
    },
  },
  opts = {}, -- Automates require("tabscope").setup({}) when loaded
}

-- ============================================================================
-- 3. Returning multiple plugins from one file (e.g., ~/.config/nvim/lua/plugins/ui.lua)
-- ============================================================================

-- If you want to group related plugins in a single file, you can return a list
-- (an array) of plugin specs instead of just one.

-- return {
--   {
--     "catppuccin/nvim",
--     as = "catppuccin",
--     priority = 1000, -- Load colorscheme early
--   },
--   {
--     "nvim-lualine/lualine.nvim",
--     dependencies = { "nvim-tree/nvim-web-devicons" },
--     opts = {
--       options = { theme = "catppuccin" }
--     }
--   }
-- }
