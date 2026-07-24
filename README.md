# 📦 pack.nvim

A modern, high-performance Neovim plugin manager that leverages Neovim's built-in native package management (`:help packages`, `vim.pack`) while providing a rich, interactive, floating-window UI.

Unlike traditional native pack managers (like `minpac` or `paq-nvim`), **pack.nvim** focuses on developer experience with a beautiful dashboard, non-blocking asynchronous git operations, and real-time log streaming.

## ✅ Requirements

* **Neovim 0.12+** — pack.nvim delegates all cloning, checkout, updating, pinning, and lockfile management to Neovim's built-in **`vim.pack`** API, which only exists in 0.12 and later. On an older Neovim, `setup()` warns and does nothing.
* **`git`** on your `PATH`.

## ✨ Features

* **Native Backend:** All plugins install under `vim.pack`'s directory (`<stdpath("data")>/site/pack/core/opt`). Every plugin (lazy or not) is `packadd`-ed explicitly through pack rather than relying on Neovim's `start/` auto-load, so lazy loading and ordered eager loading are fully under pack's control.
* **Native Git, Async Probes:** Clone / checkout / update / pinning are handled by native `vim.pack`. pack.nvim layers on non-blocking, **concurrency-limited** read-only git probes (via `vim.system`) purely to power the dashboard's "outdated" indicator and commit preview.
* **Interactive UI Dashboard:** A centralized floating window showing real-time plugin statuses, log streaming, and pending-commit previews for outdated plugins.
* **Reproducible installs:** Version pinning (`branch` / `tag` / `commit` / semver `version` ranges) is resolved to a native `vim.pack` spec; native owns the lockfile, and `:Pack restore` rolls every plugin back to it.
* **Persistent Disable State:** Disabling a plugin is persisted (see [Disabling plugins](#-disabling-plugins)) without editing your raw Lua config.
* **Performance Caching:** Pre-compiles lazy plugins' `ftdetect` files into a single cache block, sourced at startup so their filetypes are detected before the plugin loads.
* **Lazy Loading:** Supports `cmd`, `event` (with patterns), `ft` (filetype), and `keys` (keymap) triggers to load plugins right when you need them.
* **Modular Configuration:** Keep your config clean by using `{ import = "plugins" }` to split specs across multiple files.
* **Fine-Grained Loading Control:** Toggle plugins with `enabled` or `cond`, and guarantee eager-load order using `priority`.
* **Help Tags:** `:help` tags are generated automatically for every managed plugin's `doc/` directory on load.
* **Health Check:** Run `:checkhealth pack` to verify your Neovim version, `git`, the install directory, per-plugin status, and orphaned directories.

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
Run custom build steps after a plugin is installed or updated. `build` accepts the
same forms as lazy.nvim — a shell string, a `:Command` string, a Lua function, or a
list of any of those run in sequence:
```lua
{
  "nvim-telescope/telescope-fzf-native.nvim",
  build = "make",                       -- shell command
}
{
  "nvim-treesitter/nvim-treesitter",
  build = ":TSUpdate",                  -- Vim ex-command (leading ':')
}
{
  "saghen/blink.cmp",
  build = function(plugin) end,         -- Lua function, gets the plugin context
}
{
  "some/plugin",
  build = { ":Cmd", "make", function() end },  -- list, run in order
}
```
> Build strings run through the shell (`sh -c`, or `cmd /c` on Windows) — treat them as trusted config only, never a value pulled from a remote source.

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
Debug slow startup times by viewing precisely how long each plugin took to load during initialization using the `:Pack profile` command (or `p` inside the dashboard).

### Commit Previews
When a plugin is behind its upstream, the dashboard shows the pending commits (`git log HEAD..origin/<branch>`) and the before/after revisions, so you can see exactly what an update will pull in.

### Dashboard Filtering
Search a large plugin list by typing `/` to filter the dashboard by name in real-time.

## 🚀 Installation & Bootstrapping

pack.nvim is designed to manage itself. Add this bootstrap snippet to the very top of your `init.lua`:

```lua
local pack_path = vim.fn.stdpath("data") .. "/site/pack/core/opt/pack.nvim"

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
end

-- Add to runtime path unconditionally
vim.opt.rtp:prepend(pack_path)

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

pack.nvim and native `vim.pack` share the exact same install directory
(`<stdpath("data")>/site/pack/core/opt/<name>`), so any plugin already installed via
`vim.pack.add()` is recognized as `installed` immediately, with no re-clone — just list it in your spec:

```lua
require("pack").setup({
  plugins = {
    { "nvim-lua/plenary.nvim" }, -- already on disk from vim.pack.add() -> just gets packadd'd
  },
})
```

After `setup()`, pack.nvim replaces the global `vim.pack.add`/`vim.pack.update`/`vim.pack.del` with
lazy-aware wrappers, so you can keep calling `vim.pack.add({ ... })` and it flows through pack.nvim's
loader. The install location and lockfile are owned by native `vim.pack` and are not configurable.

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
| `:Pack sync` | Updates all managed plugins via native `vim.pack`. |
| `:Pack update [name]` | Updates a single plugin (or all plugins if no name is given). |
| `:Pack clean` | Removes plugin directories no longer referenced in your configuration. |
| `:Pack restore` | Rolls every plugin back to the native `vim.pack` lockfile. |
| `:Pack build [name]` | Re-runs the `build` hook for one plugin (or all plugins). |
| `:Pack load <name>` | Immediately loads a lazy plugin. |
| `:Pack delete <name>` | Removes a plugin from state and deletes it via native `vim.pack`. |
| `:Pack profile` | Displays the startup profile showing plugin load times. |

Subcommands with a `<name>` argument tab-complete against your configured plugins.

## ⌨️ Dashboard Keymaps

When inside the dashboard (opened via `:Pack`), you can use the following keymaps:

*   `q` - Close the dashboard or any popup.
*   `g?` - Show the full keymap help popup.
*   `S` - Start a Sync operation (install/update).
*   `Tab` (or `1`/`2`/`3`) - Cycle tabs: All -> Outdated -> Disabled.
*   `<Enter>` - Quick details for the plugin under the cursor.
*   `K` - Full details (includes current commit) for the plugin under the cursor.
*   `l` - Show git output logs for the plugin under the cursor.
*   `p` - Show the startup profile.
*   `x` - Toggle disable/enable for the plugin under the cursor (All and Disabled tabs); see [Disabling plugins](#-disabling-plugins). An already-loaded plugin needs a restart to fully unload.
*   `c` - Check for outdated plugins (concurrency-limited `git fetch`, skipping any checked within the last few minutes).
*   `u` - Update the plugin under the cursor (Outdated tab).
*   `U` - Update every outdated plugin (Outdated tab).
*   `/` - Filter the dashboard by plugin name (substring match).

## 🚫 Disabling plugins

Pressing `x` on a plugin (or calling `require("pack.state").set_disabled(name, true)`) persists the
disabled set to `nvim-pack-extra.json` in your Neovim **config** directory. The file is a nested JSON
object, so prefer toggling via the dashboard rather than hand-editing:

```json
{ "plugins": { "foo.nvim": { "disabled": true } } }
```

A disabled plugin is never `packadd`-ed or handed to native `vim.pack`, and any direct `require()` of it
returns a harmless mock so unconditional `require`s in your config don't error.

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

Several declarative spec and lazy-loading features (such as `import`, programmatic conditionals, advanced event pattern matching, and context-aware hook variables) were heavily inspired by [zpack.nvim](https://github.com/zuqini/zpack.nvim) and its foundational homage to `lazy.nvim`. pack.nvim combines these elegant spec configurations with a rich asynchronous floating dashboard on top of Neovim's native `vim.pack` backend.
