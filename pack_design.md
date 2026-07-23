# Pack UI - Native Neovim Plugin Manager Design Document

## 1. Overview
The goal is to build a modern, high-performance Neovim plugin manager that leverages Neovim's built-in native package management (`:help packages`, `vim.pack`) while providing a rich, interactive, floating-window UI similar to `lazy.nvim`.

Unlike traditional native pack managers (which are often strictly CLI-based like `minpac` or `paq-nvim`), this plugin focuses on **developer experience** with a beautiful dashboard, asynchronous operations, and clear status reporting.

## 2. Core Features
*   **Native Backend:** Exclusively uses `~/.local/share/nvim/site/pack/<namespace>/{start,opt}`.
*   **Async Git Operations:** Non-blocking `git clone` and `git pull` using `vim.uv` (libuv) to ensure the UI never freezes.
*   **Rich Floating UI:** A centralized dashboard showing plugin statuses (Installed, Missing, Loaded, Outdated).
*   **Lazy Loading via `opt`:** Place plugins in the `opt/` folder and dynamically call `vim.cmd("packadd " .. name)` based on events, commands, or filetypes.
*   **Simple Configuration:** A declarative configuration table heavily inspired by `lazy.nvim`.

## 3. Directory Structure
```lua
~/.local/share/nvim/site/pack/packui/
├── start/
│   ├── plenary.nvim/    # Auto-loaded on startup
│   └── telescope.nvim/  # Auto-loaded on startup
└── opt/
    ├── nvim-treesitter/ # Loaded manually via packadd
    └── fff.nvim/        # Loaded manually via packadd
```

## 4. Configuration Schema
The user configuration should be declarative:

```lua
require("packui").setup({
  -- The directory where plugins will be installed
  install_path = vim.fn.stdpath("data") .. "/site/pack/packui",
  
  -- The plugins to install
  plugins = {
    { "nvim-lua/plenary.nvim" },
    { 
      "nvim-telescope/telescope.nvim", 
      lazy = true, 
      cmd = "Telescope",
      config = function()
        require("telescope").setup()
      end
    },
    { "catppuccin/nvim", as = "catppuccin" }
  },
  
  -- UI Customization
  ui = {
    border = "rounded",
    icons = {
      loaded = "●",
      not_loaded = "○",
      error = "✖",
      sync = "↺"
    }
  }
})
```

## 5. Architectural Components

### A. The State Manager
Tracks the current state of defined plugins vs. installed directories.
*   Scans the `start/` and `opt/` directories on startup.
*   Diffs the filesystem against the user's `plugins` table.
*   Identifies missing plugins (need to be cloned) and orphaned plugins (need to be cleaned).

### B. The Async Job Runner
Handles external shell commands without blocking the Neovim event loop.
*   Uses `vim.uv.spawn()` for `git clone` and `git status`.
*   Passes `stdout` and `stderr` streams directly to the UI for real-time progress bars and logging.

### C. The UI Engine
The visual layer of the plugin manager.
*   Creates a centered floating window (`vim.api.nvim_open_win`).
*   Uses a dedicated, non-modifiable scratch buffer (`buftype=nofile`).
*   **Layout:**
    *   **Header:** Title, total plugin count, timing stats.
    *   **Body:** List of plugins grouped by status (e.g., `[Loaded]`, `[Not Loaded]`, `[Installing...]`).
    *   **Footer/Keymaps:** `[I]nstall`, `[U]pdate`, `[C]lean`, `[S]ync`, `[q]uit`.
*   Uses `nvim_buf_add_highlight` (extmarks) for vibrant, granular syntax highlighting of icons, plugin names, and commit hashes.

### D. The Loader (Lazy Loading)
Interacts with native vim functionality.
*   Iterates over plugins marked `lazy = true`.
*   Sets up `vim.api.nvim_create_autocmd` for events (`CmdUndefined`, `FileType`).
*   When triggered, executes `vim.cmd("packadd " .. plugin.name)` and then runs the user's `config()` function.

## 6. Implementation Roadmap

*   **Phase 1: Core Logic.** Write the declarative spec parser and the `git` async wrapper to clone repositories into `pack/packui/start`.
*   **Phase 2: Basic UI.** Create the floating window and list the plugins. Implement basic keymaps to trigger the install/update jobs and stream `stdout` to a split window.
*   **Phase 3: Polishing the UI.** Implement custom highlights, icons, grouping (Loaded vs Unloaded), and a split-view detail pane (like lazy.nvim) for viewing commit logs.
*   **Phase 4: Lazy Loading Engine.** Implement the logic to place plugins in `opt/`, intercept Vim events (like `CmdlineEnter` or `FileType`), and seamlessly execute `packadd`.
