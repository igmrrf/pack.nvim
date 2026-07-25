# 📦 pack.nvim

A modern, high-performance Neovim plugin manager that leverages Neovim's built-in native package management (`:help packages`, `vim.pack`) while providing a rich, interactive, floating-window UI.

![pack.nvim Dashboard](https://media.githubusercontent.com/media/igmrrf/brand-assets/refs/heads/main/projects/pack.nvim/All.jpg)

Unlike traditional native pack managers (like `minpac` or `paq-nvim`), **pack.nvim** focuses on developer experience with a beautiful dashboard, non-blocking asynchronous git operations, and real-time log streaming.

## ✅ Requirements

* **Neovim 0.12+** — pack.nvim delegates all cloning, checkout, updating, pinning, and lockfile management to Neovim's built-in **`vim.pack`** API, which only exists in 0.12 and later. On an older Neovim, `setup()` warns and does nothing.
* **`git`** on your `PATH`.

## ✨ Features

* **Native Backend:** All plugins install under `vim.pack`'s directory (`<stdpath("data")>/site/pack/core/opt`). Every plugin (lazy or not) is `packadd`-ed explicitly through pack rather than relying on Neovim's `start/` auto-load, so lazy loading and ordered eager loading are fully under pack's control.
* **Native Git, Async Probes:** Clone / checkout / update / pinning are handled by native `vim.pack`. pack.nvim layers on non-blocking, **concurrency-limited** read-only git probes (via `vim.system`) purely to power the dashboard's "outdated" indicator and commit preview.
* **Interactive UI Dashboard:** A centralized floating window showing real-time plugin statuses, log streaming, and pending-commit previews for outdated plugins.
* **Reproducible installs:** Version pinning (`branch` / `tag` / `commit` / semver `version` ranges) is resolved to a native `vim.pack` spec; native owns the lockfile, and `:Pack restore` rolls every plugin back to it.
* **Persistent Disable State:** Disabling a plugin (via `x` in the dashboard or `set_disabled()`) persists state to `nvim-pack-extra.json` without editing your raw Lua config.
* **Performance Caching:** Pre-compiles lazy plugins' `ftdetect` files into a single cache block, sourced at startup so their filetypes are detected before the plugin loads.
* **Lazy Loading:** Supports `cmd`, `event` (with patterns), `ft` (filetype), and `keys` (keymap) triggers to load plugins right when you need them.
* **Modular Configuration:** Keep your config clean by using `{ import = "plugins" }` to split specs across multiple files.
* **Fine-Grained Loading Control:** Toggle plugins with `enabled` or `cond`, and guarantee eager-load order using `priority`.
* **Help Tags:** `:help` tags are generated automatically for every managed plugin's `doc/` directory on load.
* **Health Check:** Run `:checkhealth pack` to verify your Neovim version, `git`, the install directory, per-plugin status, and orphaned directories.

## 🚀 Installation & Bootstrapping

pack.nvim leverages Neovim 0.12's native `vim.pack` for bootstrapping. Add this snippet to the top of your `init.lua`:

```lua
vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- 1. Bootstrap pack.nvim using Neovim's native vim.pack
vim.pack.add({ { src = "https://github.com/igmrrf/pack.nvim", branch = "main" } })
vim.cmd.packadd("pack.nvim")

-- 2. Initialize pack.nvim with options and plugin specs
require("pack").setup({
  performance = {
    vim_loader = true, -- Enables Neovim's built-in bytecode cache (vim.loader.enable())
  },
  ui = {
    border = "rounded", -- Options: "single", "double", "rounded", "solid", "shadow"
    icons = {
      loaded = "●",
      not_loaded = "○",
      error = "✖",
      sync = "↺",
    },
  },
  plugins = {
    { "igmrrf/pack.nvim" }, -- So pack.nvim can manage itself (updates, status, lockfile)
    { import = "plugins" },  -- Import specs from lua/plugins/* (files can call vim.pack.add or return a spec table)
  },
})

require("configs")
```

For alternative installation patterns (e.g. `vim.uv.fs_stat` fallback, raw git cloning), see the [examples/](examples/) directory.

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

#### Known limitations when mixing styles

*   **Raw `vim.pack.add` before `setup()`, then declared with `config`/`opts`**: if a plugin is
    installed/activated via a *raw* `vim.pack.add()` call before `require('pack').setup()` runs, and
    is *also* declared in your `plugins` spec with a `config` or `opts`, that `config` will **not**
    run. Native `vim.pack` already considers the plugin active and early-returns when pack.nvim's
    wrapper re-adds it, so our loader never gets a chance to fire. Either declare such plugins only
    through pack.nvim, or avoid raw pre-`setup()` adds for anything that needs a `config`.
*   **Imperative imports vs. declarative priority ordering**: eager-load `priority` ordering is only
    guaranteed *among declarative plugins*. Plugins registered via imperative `vim.pack.add` calls
    inside `{ import = ... }` files load in import order during `setup()`, not as part of the global
    priority sort.
*   **First registration wins**: if the same plugin is registered both by an imperative
    `vim.pack.add` during an import and by a declarative spec, the first registration wins and the
    later spec's fields (`lazy`/`config`/`keys`/`opts`) are silently ignored; declare each plugin
    once, in one style.

## 📋 Plugin Specification

Plugin specifications can be defined as shorthand strings (`"owner/repo"`), tables, or URLs. Here is a comprehensive reference of supported spec keys:

| Key | Type | Description |
| :--- | :--- | :--- |
| `[1]` / `src` | `string` | Plugin repository (`"owner/repo"`), full Git URL, or local path. |
| `as` / `name` | `string` | Custom name or directory alias for the plugin. |
| `dir` | `string` | Path to a local development plugin (bypasses git cloning). |
| `lazy` | `boolean` | When `true`, defers loading until triggered by `cmd`, `event`, `ft`, `keys`, or `require()`. |
| `priority` | `number` | Load order priority for eager plugins (higher values load first, default `50`). |
| `enabled` | `boolean\|fun():boolean` | Toggle to enable or completely skip this plugin spec. |
| `cond` | `boolean\|fun(plugin):boolean` | Conditional expression or callback function to gate plugin loading. |
| `main` | `string` | Overrides the target module name passed to `opts` auto-setup. |
| `cmd` | `string\|table` | User command(s) that trigger lazy loading. |
| `ft` | `string\|table` | Filetype(s) that trigger lazy loading. |
| `event` | `string\|table` | Autocmd event(s) or pattern(s) that trigger lazy loading (e.g. `"BufReadPre"`). |
| `keys` | `string\|table` | Keymap shortcut(s) that trigger lazy loading or register keybindings. |
| `dependencies` | `table` | List of dependent plugin specs loaded prior to this plugin. |
| `init` | `fun(plugin)` | Callback executed BEFORE the plugin is loaded (useful for setting `vim.g` options). |
| `opts` | `table` | Options table automatically passed to `require(main).setup(opts)`. |
| `config` | `fun(plugin, opts)` | Custom callback executed AFTER the plugin is loaded (overrides default `opts` behavior). |
| `build` | `string\|fun(plugin)` | Shell command or Lua function executed post-install / update. |
| `branch` | `string` | Track a specific git branch. |
| `tag` | `string` | Pin to a specific git tag. |
| `commit` | `string` | Pin to a specific git commit hash. |
| `version` | `string` | Pin to a semver version range (e.g. `"^1.0.0"`). |
| `category` | `string` | Category metadata tag for filtering in the dashboard (`/cat:lsp`). |
| `tags` | `string\|table` | Custom tag string or table of tags for dashboard filtering (`/tag:ui`). |

## 🔌 Lua API

pack.nvim exposes programmatic Lua helper functions for configuration and key mapping:

* **`require("pack").setup(opts)`**: Initializes pack.nvim with user configuration and plugin specs.
* **`require("pack").add(specs)`**: Programmatically registers and installs new plugin specs post-startup.
* **`require("pack").map_keys(keys)`**: Registers a list of keymaps in a single call:
  ```lua
  require("pack").map_keys({
    { "<leader>e", "<cmd>Oil<cr>", desc = "Open Oil" },
    { "<leader>gg", function() require("snacks").lazygit() end, desc = "Lazygit", mode = { "n", "v" } },
  })
  ```
* **`require("pack.state").set_disabled(name, disabled)`**: Programmatically enables or disables a plugin and persists state to `nvim-pack-extra.json`.


## ⚡ Advanced Capabilities & Examples

For full configuration examples and migration guides, see the [examples/](examples/) directory:

- **[Basic Bootstrap](examples/01_basic_bootstrap.lua):** Standard `vim.uv.fs_stat` + `git clone` bootstrapping snippet.
- **[Native vim.pack Bootstrap](examples/06_native_vim_pack_bootstrap.lua):** Minimal 0.12+ native `vim.pack.add` bootstrapping.
- **[Dependency Management](examples/03_advanced_hooks.lua):** Automatically clone and load dependencies (`dependencies = { ... }`).
- **[Post-Install & Build Hooks](examples/03_advanced_hooks.lua):** Execute shell commands, Vim commands, or Lua functions post-update (`build = ...`).
- **[Context-Aware Initialization](examples/03_advanced_hooks.lua):** Use `init`, `config`, `cond`, and `build` with rich `Plugin` object context.
- **[Lazy Loading Triggers](examples/02_lazy_loading.lua):** Defer plugins by `cmd`, `event`, `ft`, `keys`, or `cond`.
- **[Modular Configs](examples/08_modular_configuration.lua):** Split plugin specs cleanly using `{ import = "plugins" }`.
- **[Full Spec Reference](examples/07_all_features_spec.lua):** View an exhaustive example spec showing all available options.
- **[Migration Guides](examples/):** Guides for migrating from [lazy.nvim](examples/09_migration_from_lazy.lua), [packer.nvim](examples/10_migration_from_packer.lua), or [imperative vim.pack](examples/11_migration_imperative.lua).


## 💻 Commands

| Command | Description |
|---|---|
| `:Pack` | Opens the interactive dashboard UI to view current plugin status. |
| `:Pack sync` | Updates all managed plugins via native `vim.pack`. |
| `:Pack update [name]` | Updates a single plugin (or all plugins if no name is given). |
| `:Pack clean` | Removes plugin directories no longer referenced in your configuration. |
| `:Pack restore` | Rolls every plugin back to the native `vim.pack` lockfile. |
| `:Pack repair` | Realigns lockfile (`nvim-pack-lock.json`) revisions to installed plugin HEAD commits. |
| `:Pack build [name]` | Re-runs the `build` hook for one plugin (or all plugins). |
| `:Pack load <name>` | Immediately loads a lazy plugin. |
| `:Pack delete <name>` | Removes a plugin from state and deletes it via native `vim.pack`. |
| `:Pack profile` | Displays the startup profile with visual bar charts showing plugin load times. |
| `:Pack diff` | Displays a structured diff of pending commits for outdated plugins before updating. |

Subcommands with a `<name>` argument tab-complete against your configured plugins.

### 📸 UI Showcase

| Dashboard View | Plugin Quick Details |
| :---: | :---: |
| **All Plugins**<br>![All Plugins](https://media.githubusercontent.com/media/igmrrf/brand-assets/refs/heads/main/projects/pack.nvim/All.jpg) | **Detailed Info Popup (`<Enter>` / `K`)**<br>![Plugin Info](https://media.githubusercontent.com/media/igmrrf/brand-assets/refs/heads/main/projects/pack.nvim/All_info.jpg) |
| **Outdated Updates View**<br>![Outdated Plugins](https://media.githubusercontent.com/media/igmrrf/brand-assets/refs/heads/main/projects/pack.nvim/Outdated.jpg) | **Outdated Plugin Info & Diff**<br>![Outdated Info](https://media.githubusercontent.com/media/igmrrf/brand-assets/refs/heads/main/projects/pack.nvim/Outdated_info.jpg) |
| **Disabled Plugins View**<br>![Disabled Plugins](https://media.githubusercontent.com/media/igmrrf/brand-assets/refs/heads/main/projects/pack.nvim/Disabled.jpg) | **Disabled Plugin Info**<br>![Disabled Info](https://media.githubusercontent.com/media/igmrrf/brand-assets/refs/heads/main/projects/pack.nvim/Disabled_info.jpg) |

## ⌨️ Dashboard Keymaps

When inside the dashboard (opened via `:Pack`), you can use the following keymaps:

*   `q` - Close the dashboard or any popup.
*   `g?` - Show the full keymap help popup.
*   `S` - Start a Sync operation (install/update).
*   `Tab` (or `1`/`2`/`3`) - Cycle tabs: All -> Outdated -> Disabled.
*   `<Enter>` - Quick details for the plugin under the cursor.
*   `K` - Full details (includes branch, working tree status, and current commit) for the plugin under the cursor.
*   `l` - Show git output logs for the plugin under the cursor.
*   `p` - Show the startup profile with visual bar chart.
*   `d` - View pending updates diff for outdated plugins.
*   `x` - Toggle disable/enable for the plugin under the cursor (All and Disabled tabs). An already-loaded plugin needs a restart to fully unload.
*   `c` - Check for outdated plugins (concurrency-limited `git fetch`, skipping any checked within the last few minutes).
*   `u` - Update the plugin under the cursor (Outdated tab).
*   `U` - Update every outdated plugin (Outdated tab).
*   `/` - Filter the dashboard by plugin name, category (`/cat:lsp`), or tag (`/tag:ui`).

## 📊 Comparison Matrix

| Feature / Dimension | `pack.nvim` | `lazy.nvim` | `pckr.nvim` | `paq-nvim` | `vim-plug` |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Minimum Neovim** | **0.12+** (Requires `vim.pack`) | 0.8+ | 0.7+ | 0.5+ | Vim 7.4 / Neovim 0.2+ |
| **Backend Engine** | Native C (`vim.pack`) | Custom Lua engine | Native `packpath` | Native `packpath` | Custom Vimscript engine |
| **Storage Location** | `<stdpath("data")>/site/pack/core/opt` | `<stdpath("data")>/lazy` | `<stdpath("data")>/site/pack/pckr/opt` | `<stdpath("data")>/site/pack/paq/opt` | `~/.config/nvim/plugged` |
| **Lockfile Format** | Native `nvim-pack-lock.json` | Custom `lazy-lock.json` | Custom lockfile | None | None (snapshots) |
| **Codebase Size** | **~2,000 lines of Lua** | ~20,000+ lines of Lua | ~3,500 lines of Lua | ~600 lines of Lua | ~2,700 lines of Vimscript |
| **Lazy Loading Triggers** | `cmd`, `event`, `ft`, `keys`, `cond` | `cmd`, `event`, `ft`, `keys`, `cond`, custom | `cmd`, `event`, `ft`, `keys`, `cond` | None (Eager / `packadd` only) | `on` (cmd), `for` (ft) |
| **Dependency Support** | Yes (`dependencies`) | Yes (`dependencies`) | Yes (`requires`) | No | No (manual order) |
| **Modular Specs** | Yes (`{ import = "..." }`) | Yes (`{ import = "..." }`) | No | No | No |
| **Precompiled `ftdetect` Cache** | Yes (`pack_ftdetect_cache.lua`) | Yes | No | No | No |
| **Interactive Dashboard** | Floating UI with tabs, `/` search, commit diffs | Full-featured floating UI dashboard | Minimal floating log buffer | Minimal log buffer | Vim split buffer |
| **Startup Profiling** | Built-in (`:Pack profile` ASCII charts) | Built-in (Timeline breakdown) | Built-in (`:Pckr profile`) | None | Built-in (`:PlugStatus`) |
| **Build Hooks** | `build` (shell, `:cmd`, fn, list) | `build` (shell, `:cmd`, fn, list) | `run` (shell, fn, list) | `build` (shell, fn) | `do` (shell, fn) |
| **Native Plugin Adoption** | Yes (adopts disk plugins via `vim.pack.get`) | No (requires managed dir) | Partial | Partial | No |
| **Maintenance Model** | **Feature-frozen** (stable & bug fixes) | Active development | Maintenance | Minimal / Stable | Maintenance |

## 🔒 Maintenance & Feature Policy

`pack.nvim` is **feature-complete, fully tested, and production-ready**. 

To preserve its zero-dependency model, ultra-fast startup, and rock-solid stability, **the codebase is under a strict feature freeze**:
- **Bug fixes & Neovim compatibility updates** are actively maintained.
- **New core features** will only be considered if requested and endorsed by **10 or more active users** via GitHub Issues/Discussions.

## 🙏 Acknowledgements

Several declarative spec and lazy-loading features (such as `import`, programmatic conditionals, advanced event pattern matching, and context-aware hook variables) were heavily inspired by [zpack.nvim](https://github.com/zuqini/zpack.nvim) and its foundational homage to `lazy.nvim`. pack.nvim combines these elegant spec configurations with a rich asynchronous floating dashboard on top of Neovim's native `vim.pack` backend.

