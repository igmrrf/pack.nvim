# 📦 pack.nvim

A modern, high-performance Neovim plugin manager that leverages Neovim's built-in native package management (`:help packages`, `vim.pack`) while providing a rich, interactive, floating-window UI.

Unlike traditional native pack managers (like `minpac` or `paq-nvim`), **pack.nvim** focuses on developer experience with a beautiful dashboard, non-blocking asynchronous git operations, and real-time log streaming.

## ✨ Features

* **Native Backend:** Exclusively uses `~/.local/share/nvim/site/pack/pack/opt`. Every plugin (lazy or not) is `packadd`-ed explicitly through pack rather than relying on Neovim's native `start/` auto-load, which only scans 'packpath' entries that existed *before* `setup()` ever runs.
* **Async Git Operations:** Non-blocking `git clone` and `git pull` utilizing `vim.uv` (libuv) with safe concurrency limits.
* **Interactive UI Dashboard:** A centralized floating window showing real-time plugin statuses, log streaming, and lockfile diffs.
* **Lockfile Support:** Generates and respects `nvim-pack-lock.json` to ensure reproducible plugin installations across machines.
* **Persistent States:** Disabling a plugin is persisted to `pack-disabled.json` without needing to modify your raw Lua configuration.
* **Performance Caching:** Pre-compiles all lazy-loaded `ftdetect` files into a single cache block to avoid synchronous I/O blocks during Neovim startup.
* **Lazy Loading:** Seamlessly supports `cmd`, `event` (with patterns), `ft` (filetype), and `keys` (keymap) triggers to dynamically load plugins right when you need them.
* **Modular Configuration:** Keep your config clean by using `{ import = "plugins" }` to automatically split and load specs across multiple files.
* **Fine-Grained Loading Control:** Programmatically toggle plugins with `enabled` or `cond`, and guarantee eager-load execution order using `priority`.

## 🚀 Advanced Features

### Dependency Management
Define dependencies that will be automatically installed and loaded before your main plugin.
```lua
{
  "nvim-telescope/telescope.nvim",
  dependencies = { "nvim-lua/plenary.nvim" }
}
```

### Post-Install & Build Hooks
Run custom build commands or Lua functions after a plugin is installed or updated.
```lua
{
  "nvim-telescope/telescope-fzf-native.nvim",
  build = "make" -- Or use a lua function: build = function(plugin) ... end
}
```

### Context-Aware Initialization
Hooks like `config`, `init`, `cond`, and `build` pass a rich `Plugin` object containing its filesystem `.path` and `.spec`, allowing dynamic configurations.
```lua
{
  "nvim-lualine/lualine.nvim",
  init = function(plugin)
    -- Guaranteed to run before the plugin loads
    vim.g.lualine_plugin_dir = plugin.path
  end,
  config = function(plugin, opts)
    -- Runs after load
    require("lualine").setup(opts)
  end
}
```

### Conditional Loading & Priorities
Easily sort eager plugins or ignore them entirely.
```lua
{
  "folke/tokyonight.nvim",
  priority = 1000, -- Ensure colorscheme loads before everything else
  cond = not vim.g.vscode, -- Skip loading if running inside VSCode
}
```

### Local Plugin Support
Develop plugins locally without needing a remote repository.
```lua
{
  "my-local-plugin",
  dir = "~/projects/my-local-plugin"
}
```

### Startup Profiling
Debug slow startup times by viewing precisely how long each plugin took to load during initialization using the `:Pack profile` command.

### Lockfile Diffs & Commit Histories
After `:Pack sync`, the UI visually diffs the lockfile changes, displaying the exact pending commits before you update.

### Dashboard Filtering
Easily search through a massive plugin list by typing `/` to filter the Pack dashboard in real-time.

## 🚀 Installation & Bootstrapping

pack.nvim is designed to manage itself. Add this bootstrap snippet to the very top of your `init.lua`:

```lua
local pack_path = vim.fn.stdpath("data") .. "/site/pack/pack/opt/pack.nvim"

-- Automatically clone pack.nvim if it's not installed
if not vim.uv.fs_stat(pack_path) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/igmrrf/pack.nvim.git",
    "--branch=main",
    pack_path,
  })
  
  -- Add to runtime path on the very first run
  vim.opt.rtp:prepend(pack_path)
end

-- Initialize pack.nvim
require("pack").setup({
  plugins = {
    -- Let pack.nvim manage itself!
    { "igmrrf/pack.nvim" },

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
the repo's basename — the exact same `pack/<group>/opt/<name>` layout pack.nvim uses. Point `install_path`
at that same directory and pack.nvim recognizes every already-installed plugin as `installed` immediately,
with no re-clone:

```lua
require("pack").setup({
  install_path = vim.fn.stdpath("data") .. "/site/pack/core",
  plugins = {
    { "nvim-lua/plenary.nvim" }, -- already on disk from vim.pack.add() -> just gets packadd'd
  },
})
```

Make sure nothing else still calls `vim.pack.add()`/`vim.pack.update()` for the same plugins once pack.nvim
is managing them — both would otherwise try to install/update the same directories.

### Bulk keymaps

`require("pack").map_keys({ ... })` registers a list of keymaps in one call — handy inside a plugin's `config` function:

```lua
require("pack").map_keys({
  { "<leader>e", "<cmd>Oil<cr>", desc = "Open Oil" },
  { "<leader>gg", function() require("snacks").lazygit() end, desc = "Lazygit", mode = { "n", "v" } },
})
```

## 💻 Commands

| Command | Description |
|---|---|
| `:Pack` | Opens the interactive dashboard UI to view current plugin status. |
| `:Pack sync` | Installs missing plugins and updates existing plugins using parallel async workers. |
| `:Pack clean` | Automatically removes plugin directories that are no longer referenced in your configuration. |
| `:Pack profile` | Displays the startup profile showing plugin load times. |

## ⌨️ Dashboard Keymaps

When inside the dashboard (opened via `:Pack`), you can use the following keymaps:

*   `q` - Close the dashboard or any popup.
*   `?` - Show the full keymap help popup.
*   `S` - Start a Sync operation (install/update).
*   `Tab` - Cycle tabs: All -> Outdated -> Disabled.
*   `<Enter>` - Quick details for the plugin under the cursor.
*   `K` - Full details (includes current commit) for the plugin under the cursor.
*   `l` - Show git output logs for the plugin under the cursor.
*   `x` - Toggle disable/enable for the plugin under the cursor (All and Disabled tabs). Disabling persists to `pack-disabled.json` in your Neovim config directory (a plain JSON array of plugin names, e.g. `["foo.nvim", "bar.nvim"]` — safe to hand-edit); an already-loaded plugin needs a restart to fully unload.
*   `c` - Check for outdated plugins (runs `git fetch` for every installed plugin).
*   `u` - Update the plugin under the cursor (Outdated tab).
*   `U` - Update every outdated plugin (Outdated tab).
*   `/` - Native vim search.

## ⚙️ Default Configuration

You can override the default UI settings in your `.setup()` function:

```lua
require("pack").setup({
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

## 🙏 Acknowledgements

Several declarative spec and lazy-loading features (such as `import`, programmatic conditionals, advanced event pattern matching, and context-aware hook variables) were heavily inspired by [zpack.nvim](https://github.com/zuqini/zpack.nvim) and its foundational homage to `lazy.nvim`. pack.nvim combines these elegant spec configurations with its own rich asynchronous floating dashboard and interactive lockfile engine.
