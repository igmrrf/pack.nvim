-- Add this to your init.lua
local pack_path = vim.fn.stdpath("data") .. "/site/pack/pack/opt/pack.nvim"

if not vim.uv.fs_stat(pack_path) then
  vim.fn.system({
    "git", "clone", "--filter=blob:none",
    "https://github.com/igmrrf/pack.nvim.git", "--branch=main", pack_path
  })
  vim.opt.rtp:prepend(pack_path)
end

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
