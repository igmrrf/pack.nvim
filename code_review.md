# Pack UI - Code Review & Analysis

Here is a comprehensive review of the `packui.nvim` implementation against the original `pack_design.md` and Neovim best practices.

## 1. Positives & Core Achievements
*   **Architecture matches design:** The code is cleanly modularized into `init.lua`, `state.lua`, `async.lua`, `ui.lua`, and `loader.lua` as specified.
*   **Non-blocking Git:** Utilizing `vim.uv.spawn` with `libuv` successfully ensures that Neovim's main event loop isn't blocked during heavy network operations.
*   **Native package reliance:** Uses the `site/pack/packui/{start,opt}` paths seamlessly, offloading most of the heavy lifting to standard `packadd` rather than managing raw runtime paths manually.

## 2. Issues & Missing Features

### A. Async Job Concurrency Limit
*   **Current State:** When `:PackuiSync` is triggered, `async.sync()` loops through all plugins and invokes `M.install()` or `M.update_plugin()` immediately.
*   **Problem:** If the user has 50-100 plugins, this will spawn 50-100 simultaneous `git clone` or `git pull` processes. This can cause CPU starvation, network throttling, or open file descriptor limits (leading to random crashes).
*   **Recommendation:** Implement a concurrency queue/semaphore in `async.lua` to limit active jobs to a sensible number (e.g., 4 to 8 parallel workers).

### B. Missing Real-time Git Output Streaming
*   **Current State:** `async.lua` has `stdout:read_start(on_read)` where the `on_read` callback is empty.
*   **Problem:** Phase 2 of `pack_design.md` explicitly calls for streaming `stdout` to a split window or the dashboard.
*   **Recommendation:** Capture `data` inside `on_read`, store it in a ring buffer or table within `state.lua` for the corresponding plugin, and allow the user to view this log (e.g., by pressing `Enter` on a plugin in the UI).

### C. Incomplete Lazy Loading Triggers
*   **Current State:** `loader.lua` only implements lazy loading for user commands (`cmd = ...`).
*   **Problem:** Typical Neovim plugins require loading on `event` (e.g., `BufEnter`, `VimEnter`, `InsertEnter`), `ft` (Filetype), or `keys` (Keymaps). Phase 4 in the design spec mentions `FileType`. 
*   **Recommendation:** Extend `normalize` in `state.lua` to parse `ft` and `event` options, and extend `loader.init()` to create `vim.api.nvim_create_autocmd` bindings for them. Also, `opt/` plugins won't have their `ftdetect/` scripts sourced on startup, which usually requires manually globbing and `source`-ing them on `init`.

### D. Hardcoded GitHub URLs
*   **Current State:** `state.lua` normalizes all shortened URLs as `"https://github.com/" .. url`.
*   **Problem:** Doesn't allow cloning from GitLab, SourceHut, or arbitrary custom Git servers.
*   **Recommendation:** Check if `plugin[1]` already starts with `http://` or `https://` before prepending the GitHub domain.

### E. Minor UI State / Buffer Overwrites
*   **Current State:** Every `ui.update()` triggers `nvim_buf_set_lines(..., 0, -1, ...)` replacing the whole buffer.
*   **Problem:** While functionally correct for a simple UI, this removes all window cursor positions.
*   **Recommendation:** Save the cursor position (`vim.api.nvim_win_get_cursor`) before updating, and restore it after updating. Additionally, `nvim_buf_add_highlight` should be implemented to fulfill Phase 3 (Polishing the UI).

## 3. Recommended Next Steps
1.  **Refactor `async.lua`** to implement a basic worker pool or concurrency throttle.
2.  **Add `ft` and `event` triggers** to `loader.lua` using Neovim's `nvim_create_autocmd`.
3.  **Capture Git stdout** and render it in a small floating split when the user interacts with a plugin item.
