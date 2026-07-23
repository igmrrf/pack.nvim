# 📦 Pack UI

A modern, high-performance Neovim plugin manager that leverages Neovim's built-in native package management (`:help packages`, `vim.pack`) while providing a rich, interactive, floating-window UI.

Unlike traditional native pack managers (like `minpac` or `paq-nvim`), **Pack UI** focuses on developer experience with a beautiful dashboard, non-blocking asynchronous git operations, and real-time log streaming.

## ✨ Features

* **Native Backend:** Exclusively uses `~/.local/share/nvim/site/pack/packui/opt`. Every plugin (lazy or not) is `packadd`-ed explicitly through packui rather than relying on Neovim's native `start/` auto-load, which only scans 'packpath' entries that existed *before* `setup()` ever runs.
* **Async Git Operations:** Non-blocking `git clone` and `git pull` utilizing `vim.uv` (libuv) with safe concurrency limits.
* **Rich Dashboard UI:** A centralized floating window showing real-time plugin statuses.
* **Log Streaming:** Press `<CR>` on any installing or updating plugin to view real-time `stdout` and `stderr` logs in a floating split.
* **Lazy Loading:** Seamlessly supports `cmd`, `event`, `ft` (filetype), and `keys` (keymap) triggers to dynamically load plugins right when you need them.

## 🚀 Installation & Bootstrapping

Pack UI is designed to manage itself. Add this bootstrap snippet to the very top of your `init.lua`:

```lua
local packui_path = vim.fn.stdpath("data") .. "/site/pack/packui/opt/vimpack"

-- Automatically clone Pack UI if it's not installed
if not vim.uv.fs_stat(packui_path) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/igmrrf/vimpack.git",
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
    { "igmrrf/vimpack" },

    -- Example: Auto-loaded dependency
    { "nvim-lua/plenary.nvim" },

    -- Example: opts shorthand - calls require("telescope").setup(opts) for you,
    -- no need to write your own `config` function
    { 
      "nvim-telescope/telescope.nvim", 
      lazy = true, 
      cmd = "Telescope",
      opts = {
        defaults = { layout_strategy = "vertical" },
      },
    },

    -- Example: `main` overrides the inferred module name when it doesn't match
    -- the "<module>.nvim" convention (default: strip a trailing ".nvim")
    {
      "igmrrf/arduino_nvim",
      main = "arduino-nvim",
      opts = { mode = "float" },
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
    },

    -- Example: Lazy-loaded via Keymap (loads on first press, then replays the key)
    {
      "folke/flash.nvim",
      lazy = true,
      keys = { "s", { "S", mode = { "n", "x", "o" } } },
    }
  }
})
```

### Adopting existing `vim.pack` plugins

`vim.pack` always installs into `<stdpath("data")>/site/pack/core/opt/<name>`, deriving `<name>` from
the repo's basename — the exact same `pack/<group>/opt/<name>` layout Pack UI uses. Point `install_path`
at that same directory and Pack UI recognizes every already-installed plugin as `installed` immediately,
with no re-clone:

```lua
require("packui").setup({
  install_path = vim.fn.stdpath("data") .. "/site/pack/core",
  plugins = {
    { "nvim-lua/plenary.nvim" }, -- already on disk from vim.pack.add() -> just gets packadd'd
  },
})
```

Make sure nothing else still calls `vim.pack.add()`/`vim.pack.update()` for the same plugins once Pack
UI is managing them — both would otherwise try to install/update the same directories.

### Bulk keymaps

`require("packui").map_keys({ ... })` registers a list of keymaps in one call — handy inside a plugin's `config` function:

```lua
require("packui").map_keys({
  { "<leader>e", "<cmd>Oil<cr>", desc = "Open Oil" },
  { "<leader>gg", function() require("snacks").lazygit() end, desc = "Lazygit", mode = { "n", "v" } },
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
