local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local plenary_dir = root .. "/.tests/site/pack/deps/start/plenary.nvim"
if vim.fn.isdirectory(plenary_dir) == 0 then
  vim.fn.system({
    "git", "clone", "--depth=1",
    "https://github.com/nvim-lua/plenary.nvim",
    plenary_dir,
  })
end
vim.opt.runtimepath:prepend(plenary_dir)
vim.cmd("runtime plugin/plenary.vim")
