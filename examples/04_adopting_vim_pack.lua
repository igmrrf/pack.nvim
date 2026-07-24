-- If you already drive plugins with native `vim.pack.add`, drop pack.nvim in at
-- the very top of your init.lua to hijack those calls -- layering lazy-loading,
-- config, build hooks and a dashboard on top while native vim.pack still does
-- the actual clone/checkout/update.

vim.pack.add({ "https://github.com/igmrrf/pack.nvim" })
vim.cmd.packadd("pack.nvim")

-- 1. Initialize pack.nvim. It replaces `vim.pack.add` with a lazy-aware wrapper
--    that delegates the git work back to native vim.pack.
require("pack").setup({
  plugins = {
    { "igmrrf/pack.nvim" }
  }
})

-- 2. Your existing configuration proceeds below untouched. These calls now flow
--    through pack.nvim: installed via native vim.pack, then loaded, profiled
--    and shown in the dashboard. No manual `packadd` -- eager plugins load
--    automatically.
vim.pack.add({
  "https://github.com/rafamadriz/friendly-snippets",
  { src = "https://github.com/nvim-mini/mini.nvim" },
})
