# Plan to Polish Pack UI

## 1. UI Enhancements (ui.lua)
- Create a Neovim namespace (`nvim_create_namespace`) for highlighting.
- Add highlights to the dashboard buffer (`nvim_buf_add_highlight`):
  - Dashboard Header
  - Group Headers (e.g., "Missing (1)")
  - Icons based on status (e.g., Green for Loaded, Red for Error, Yellow for Installing/Updating)
  - Plugin Names
- Ensure `show_log` split also looks good (maybe set filetype, wrap).

## 2. Lazy Loading Robustness (loader.lua)
- For `lazy = true` plugins, glob and `source` any `ftdetect/*.vim` or `ftdetect/*.lua` files during `loader.init()`. This is crucial because `packadd` isn't called initially, so Neovim won't know about these custom filetypes otherwise.

## 3. State Parsing Robustness (state.lua)
- Handle edge cases in `url:match("/([^/]+)$")` returning `nil` if there's no slash (e.g., malformed plugin name), defaulting to the full string to avoid a Lua crash.

## 4. Async improvements (async.lua)
- Implement `sync` command safely without creating multiple overlapping sync queues if the user spams `:PackuiSync`. (Currently, it just queues them up again, which could result in double-pulls).
