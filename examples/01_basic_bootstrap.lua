-- Add this to the very top of your init.lua.
-- pack.nvim requires Neovim 0.12+ and delegates all installing/updating to the
-- native vim.pack. Bootstrap pack.nvim itself with vim.pack, then hand off.
vim.pack.add({ "https://github.com/igmrrf/pack.nvim" })
vim.cmd.packadd("pack.nvim")

require("pack").setup({
  plugins = {
    -- Pack manages itself
    { "igmrrf/pack.nvim" },

    -- Simple plugin installation
    { "nvim-lua/plenary.nvim" },

    -- Simple plugin with a setup call shorthand.
    -- This translates to `require("telescope").setup({ defaults = ... })` automatically!
    {
      "nvim-telescope/telescope.nvim",
      opts = {
        defaults = { prompt_prefix = "🔍 " }
      }
    },

    -- Modular loading: load all specs from lua/plugins/*.lua automatically
    { import = "plugins" },
  }
})
