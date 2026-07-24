require("pack").setup({
  plugins = {
    -- 1. Load on Command
    {
      "nvim-telescope/telescope.nvim",
      lazy = true,
      cmd = "Telescope", -- Loads when you type :Telescope
      opts = {}
    },

    -- 2. Load on FileType
    {
      "nvim-treesitter/nvim-treesitter",
      lazy = true,
      ft = { "lua", "python", "javascript", "rust" }, -- Loads when opening these file types
    },

    -- 3. Load on Event
    {
      "catppuccin/nvim",
      as = "catppuccin",
      lazy = true,
      event = "VimEnter", -- Loads right as Neovim finishes initializing
    },

    -- 4. Load on Event with Pattern
    {
      "rust-lang/rust.vim",
      lazy = true,
      event = "BufReadPre *.rs", -- Pattern matching for events
    },

    -- 4. Load on Keymap
    {
      "folke/flash.nvim",
      lazy = true,
      keys = { 
        "s", -- Pressing 's' in normal mode loads the plugin, then replays 's'
        { "S", mode = { "n", "x", "o" } }
      },
    }
  }
})
