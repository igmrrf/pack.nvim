-- This example demonstrates an exhaustive list of all available features
-- you can use when defining a plugin spec in pack.nvim.

local pack_path = vim.fn.stdpath("data") .. "/site/pack/pack/opt/pack.nvim"
if not vim.uv.fs_stat(pack_path) then
  vim.fn.system({
    "git", "clone", "--filter=blob:none",
    "https://github.com/igmrrf/pack.nvim.git", "--branch=main", pack_path
  })
end
vim.opt.rtp:prepend(pack_path)

require("pack").setup({
  plugins = {
    {
      -- 1. Plugin Source
      "user/mega-plugin",                   -- Standard GitHub repository
      as = "mega-plugin-custom-name",       -- Custom local directory name
      -- dir = "~/projects/mega-plugin",    -- Alternative: Use a local directory directly instead of cloning
      -- url = "https://gitlab.com/...",     -- Alternative: Use a direct URL instead of "user/repo"
      
      -- 2. Loading Mechanics
      lazy = true,                          -- Ensure it doesn't load on startup
      priority = 100,                       -- If eager loaded, set priority (higher loads earlier)
      enabled = true,                       -- Hard toggle to disable plugin tracking entirely
      cond = function(plugin)               -- Condition evaluated before loading
        return not vim.g.vscode
      end,
      main = "mega.core",                   -- Specify main lua module if it differs from the repo name
      
      -- 3. Lazy-Loading Triggers
      cmd = { "MegaCommand", "MegaToggle" },-- Load when these commands are used
      ft = { "lua", "python" },             -- Load when opening specific filetypes
      event = "BufReadPre *.md",            -- Load on specific Vim events (supports patterns)
      keys = {                              -- Load on keymap
        { "<leader>m", "<cmd>MegaToggle<cr>", desc = "Toggle Mega Plugin" },
        { "M", function() require("mega.core").do_magic() end, mode = { "n", "x" } }
      },
      
      -- 4. Dependencies
      dependencies = {
        "nvim-lua/plenary.nvim",            -- These load automatically before the main plugin
        { "kyazdani42/nvim-web-devicons", lazy = true }
      },
      
      -- 5. Hooks and Configuration
      init = function(plugin)
        -- Runs BEFORE the plugin loads. Useful for setting `vim.g` variables.
        -- `plugin` object contains `.path` (filesystem path) and `.spec`
        vim.g.mega_plugin_dir = plugin.path
      end,
      
      opts = {                              -- Automatically calls `require("mega.core").setup(opts)`
        theme = "dark",
        features = { advanced = true }
      },
      
      config = function(plugin, opts)
        -- Overrides default `opts` behavior. Runs AFTER the plugin loads.
        require("mega.core").setup(opts)
        require("mega.core").apply_custom_logic()
      end,
      
      build = "make install",               -- Shell command to run after install/update
      -- build = function(plugin)           -- Alternative: Lua function build hook
      --   vim.fn.system({ "make", "-C", plugin.path })
      -- end,
      
      -- 6. Versioning (Uses git checkout)
      branch = "main",                      -- Pin to a specific git branch
      -- tag = "v1.0.0",                    -- Pin to a specific git tag
      -- commit = "abcdef1",                -- Pin to a specific git commit hash
    }
  }
})
