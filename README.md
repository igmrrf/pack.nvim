# 📦 Pack UI

A modern, high-performance Neovim plugin manager that leverages Neovim's built-in native package management (`:help packages`, `vim.pack`) while providing a rich, interactive, floating-window UI.

Unlike traditional native pack managers (like `minpac` or `paq-nvim`), **Pack UI** focuses on developer experience with a beautiful dashboard, non-blocking asynchronous git operations, and real-time log streaming.

## ✨ Features

* **Native Backend:** Exclusively uses `~/.local/share/nvim/site/pack/packui/{start,opt}`. No weird runtime path hacks.
* **Async Git Operations:** Non-blocking `git clone` and `git pull` utilizing `vim.uv` (libuv) with safe concurrency limits.
* **Rich Dashboard UI:** A centralized floating window showing real-time plugin statuses.
* **Log Streaming:** Press `<CR>` on any installing or updating plugin to view real-time `stdout` and `stderr` logs in a floating split.
* **Lazy Loading:** Seamlessly supports `cmd`, `event`, and `ft` (filetype) triggers to dynamically load plugins right when you need them.

## 🚀 Installation & Bootstrapping

Pack UI is designed to manage itself. Add this bootstrap snippet to the very top of your `init.lua`:

```lua
local packui_path = vim.fn.stdpath("data") .. "/site/pack/packui/start/packui.nvim"

-- Automatically clone Pack UI if it's not installed
if not vim.uv.fs_stat(packui_path) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/igmrrf/packui.nvim.git", -- Replace USERNAME
    "--branch=main",
    packui_path,
  })
  
  -- Add to runtime path on the very first run
  vim.opt.rtp:prepend(packui_path)
end

-- Initialize Pack UI
require("packui").setup({
  plugins = {
    -- Let Pack UI manage itself!
    { "igmrrf/packui.nvim" },

    -- Example: Auto-loaded dependency
    { "nvim-lua/plenary.nvim" },

    -- Example: Lazy-loaded via Command
    { 
      "nvim-telescope/telescope.nvim", 
      lazy = true, 
      cmd = "Telescope",
      config = function()
        require("telescope").setup()
      end
    },

    -- Example: Lazy-loaded via Filetype
    { 
      "nvim-treesitter/nvim-treesitter", 
      lazy = true, 
      ft = { "lua", "python", "javascript" } 
    },

    -- Example: Lazy-loaded via Event
    { 
      "catppuccin/nvim", 
      as = "catppuccin",
      lazy = true,
      event = "VimEnter"
    }
  }
})
```

## 💻 Commands

| Command | Description |
|---|---|
| `:Packui` | Opens the interactive dashboard UI to view current plugin status. |
| `:PackuiSync` | Installs missing plugins and updates existing plugins using parallel async workers. |

## ⌨️ Dashboard Keymaps

When inside the dashboard (opened via `:Packui`), you can use the following keymaps:

*   `S` - Start a Sync operation (install/update).
*   `<Enter>` - Show git output logs for the plugin under the cursor.
*   `q` - Close the dashboard or the log view.

## ⚙️ Default Configuration

You can override the default UI settings in your `.setup()` function:

```lua
require("packui").setup({
  ui = {
    border = "rounded", -- Options: "single", "double", "rounded", "solid", "shadow"
    icons = {
      loaded = "●",
      not_loaded = "○",
      error = "✖",
      sync = "↺"
    }
  }
})
```
