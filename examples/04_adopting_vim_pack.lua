-- If you already have a mature configuration using `vim.pack.add` directly,
-- pack.nvim can be dropped in at the very top of your init.lua to seamlessly
-- hijack those calls and manage the plugins.

local pack_path = vim.fn.stdpath("data") .. "/site/pack/pack/opt/pack.nvim"

if not vim.uv.fs_stat(pack_path) then
  vim.fn.system({
    "git", "clone", "--filter=blob:none",
    "https://github.com/igmrrf/pack.nvim.git", "--branch=main", pack_path
  })
end
vim.opt.rtp:prepend(pack_path)

-- 1. Initialize pack.nvim. It wraps `vim.pack.add` automatically!
require("pack").setup({
  install_path = vim.fn.stdpath("data") .. "/site/pack/core",
  plugins = {
    { "igmrrf/pack.nvim" }
  }
})

-- 2. Your existing configuration proceeds below untouched.
-- pack.nvim will intercept this call, measure its load time, and add it to the dashboard.
vim.pack.add({
  "https://github.com/rafamadriz/friendly-snippets",
  { src = "https://github.com/nvim-mini/mini.nvim" },
})
vim.cmd.packadd("mini.nvim")
