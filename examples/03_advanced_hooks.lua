require("pack").setup({
  plugins = {
    -- Dependencies: plenary will be installed and loaded before telescope
    {
      "nvim-telescope/telescope.nvim",
      dependencies = { "nvim-lua/plenary.nvim" },
      cmd = "Telescope",
      lazy = true,
    },

    -- Build Hooks: run 'make' after cloning/updating
    {
      "nvim-telescope/telescope-fzf-native.nvim",
      build = "make", -- can also be a function(plugin)
      lazy = true,
    },
    
    -- Context-Aware Config & Init Hooks
    {
      "nvim-lualine/lualine.nvim",
      init = function(plugin)
        -- Runs before the plugin loads
        vim.g.lualine_path = plugin.path
      end,
      config = function(plugin, opts)
        -- Runs after the plugin loads
        require("lualine").setup(opts)
      end
    },

    -- Conditional Loading & Priority
    {
      "folke/tokyonight.nvim",
      priority = 1000, -- Load early
      cond = function(plugin)
        return not vim.g.vscode -- Skip loading if in VSCode
      end,
    },

    -- Local plugins: load a plugin directly from your disk instead of git
    {
      "my-local-plugin",
      dir = "~/projects/my-local-plugin",
      config = function()
        require("my-local-plugin").setup()
      end
    }
  }
})
