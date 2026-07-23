local state = require("packui.state")

local M = {}

local win_id = nil
local buf_id = nil
local config_ref = nil
local plugin_map = {}
local ns_id = vim.api.nvim_create_namespace("packui")

local KEYMAP_HELP = {
  { key = "q", scope = "all", desc = "close" },
  { key = "?", scope = "all", desc = "show this help" },
  { key = "S", scope = "all", desc = "sync all (install missing, pull updates)" },
  { key = "Tab", scope = "all", desc = "cycle tabs: All -> Outdated -> Disabled" },
  { key = "Enter", scope = "all", desc = "quick details for plugin under cursor" },
  { key = "K", scope = "all", desc = "full details (commit info) for plugin under cursor" },
  { key = "l", scope = "all", desc = "view install/update logs for plugin under cursor" },
  { key = "x", scope = "All, Disabled", desc = "toggle disable/enable for plugin under cursor" },
  { key = "c", scope = "all", desc = "check for outdated plugins (git fetch)" },
  { key = "u", scope = "Outdated", desc = "update plugin under cursor" },
  { key = "U", scope = "Outdated", desc = "update all outdated plugins" },
  { key = "/", scope = "all", desc = "native vim search" },
}

local function open_popup(lines, opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local width = math.floor(vim.o.columns * (opts.width_pct or 0.6))
  local height = math.min(#lines + 2, math.floor(vim.o.lines * (opts.height_pct or 0.6)))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    border = "rounded",
    style = "minimal"
  })
  vim.wo[win].wrap = opts.wrap or false

  local keymap_opts = { noremap = true, silent = true }
  for _, key in ipairs(opts.close_keys or { "q" }) do
    vim.api.nvim_buf_set_keymap(buf, "n", key, "<Cmd>close<CR>", keymap_opts)
  end

  return buf, win
end

function M.show_help()
  local lines = { "  Packui Keymaps", "  ===============", "" }
  for _, entry in ipairs(KEYMAP_HELP) do
    table.insert(lines, string.format("  %-7s %-14s %s", entry.key, entry.scope, entry.desc))
  end
  open_popup(lines, { close_keys = { "q", "?", "<Esc>" } })
end

function M.open(config)
  config_ref = config
  if win_id and vim.api.nvim_win_is_valid(win_id) then
    vim.api.nvim_set_current_win(win_id)
    return
  end
  
  buf_id = vim.api.nvim_create_buf(false, true)
  vim.bo[buf_id].bufhidden = "wipe"
  vim.bo[buf_id].buftype = "nofile"
  vim.bo[buf_id].swapfile = false
  vim.bo[buf_id].filetype = "packui"
  
  local width = math.floor(vim.o.columns * 0.8)
  local height = math.floor(vim.o.lines * 0.8)
  
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)
  
  win_id = vim.api.nvim_open_win(buf_id, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    border = config.ui.border,
    style = "minimal"
  })
  
  local opts = { noremap = true, silent = true }
  vim.api.nvim_buf_set_keymap(buf_id, "n", "q", "<Cmd>close<CR>", opts)
  vim.api.nvim_buf_set_keymap(buf_id, "n", "?", "<Cmd>lua require('packui.ui').show_help()<CR>", opts)
  vim.api.nvim_buf_set_keymap(buf_id, "n", "S", "<Cmd>PackuiSync<CR>", opts)
  vim.api.nvim_buf_set_keymap(buf_id, "n", "<CR>", "<Cmd>lua require('packui.ui').show_log()<CR>", opts)
  
  M.update()
end

function M.show_log()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_idx = cursor[1]
  local p = plugin_map[line_idx]
  if not p or not p.log or #p.log == 0 then
    vim.notify("No logs available for this item.", vim.log.levels.INFO)
    return
  end
  
  local log_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[log_buf].bufhidden = "wipe"
  vim.bo[log_buf].buftype = "nofile"
  vim.bo[log_buf].swapfile = false
  
  vim.api.nvim_buf_set_lines(log_buf, 0, -1, false, p.log)
  vim.bo[log_buf].filetype = "packui_log"
  vim.bo[log_buf].modifiable = false
  
  local width = math.floor(vim.o.columns * 0.6)
  local height = math.floor(vim.o.lines * 0.6)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)
  
  local log_win = vim.api.nvim_open_win(log_buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    border = "rounded",
    style = "minimal"
  })
  vim.wo[log_win].wrap = true
  vim.api.nvim_buf_set_keymap(log_buf, "n", "q", "<Cmd>close<CR>", { noremap = true, silent = true })
end

function M.update()
  if not buf_id or not vim.api.nvim_buf_is_valid(buf_id) then
    return
  end
  
  local cursor
  if win_id and vim.api.nvim_win_is_valid(win_id) then
    cursor = vim.api.nvim_win_get_cursor(win_id)
  end
  
  local lines = {}
  plugin_map = {}
  
  table.insert(lines, "  Pack UI Dashboard")
  table.insert(lines, "  =================")
  table.insert(lines, "")
  
  local plugins = state.get_plugins()
  
  local groups = {
    loaded = {},
    installed = {},
    missing = {},
    installing = {},
    updating = {},
    error = {}
  }
  
  for _, p in pairs(plugins) do
    if groups[p.status] then
      table.insert(groups[p.status], p)
    else
      table.insert(groups.installed, p)
    end
  end

  for _, list in pairs(groups) do
    table.sort(list, function(a, b) return a.name < b.name end)
  end

  local highlights = {}
  local function render_group(name, list, icon, hl_group)
    if #list > 0 then
      table.insert(lines, "  " .. name .. " (" .. #list .. ")")
      table.insert(highlights, { line = #lines - 1, col_start = 2, col_end = -1, hl = "Title" })
      for _, p in ipairs(list) do
        local line = string.format("    %s %s", icon, p.name)
        table.insert(lines, line)
        plugin_map[#lines] = p
        local icon_start = 4
        local icon_end = 4 + #icon
        table.insert(highlights, { line = #lines - 1, col_start = icon_start, col_end = icon_end, hl = hl_group })
      end
      table.insert(lines, "")
    end
  end
  
  render_group("Missing", groups.missing, config_ref.ui.icons.not_loaded, "DiagnosticError")
  render_group("Installing", groups.installing, config_ref.ui.icons.sync, "DiagnosticWarn")
  render_group("Updating", groups.updating, config_ref.ui.icons.sync, "DiagnosticWarn")
  render_group("Loaded", groups.loaded, config_ref.ui.icons.loaded, "DiagnosticOk")
  render_group("Installed (Not Loaded)", groups.installed, config_ref.ui.icons.loaded, "DiagnosticInfo")
  render_group("Errors", groups.error, config_ref.ui.icons.error, "DiagnosticError")
  
  table.insert(lines, "  Press [S] to Sync, [Enter] to view logs, [q] to quit")
  table.insert(highlights, { line = #lines - 1, col_start = 2, col_end = -1, hl = "Comment" })
  
  vim.bo[buf_id].modifiable = true
  vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, lines)
  vim.bo[buf_id].modifiable = false
  
  vim.api.nvim_buf_clear_namespace(buf_id, ns_id, 0, -1)
  table.insert(highlights, { line = 0, col_start = 2, col_end = -1, hl = "Title" })
  table.insert(highlights, { line = 1, col_start = 2, col_end = -1, hl = "Title" })
  for _, h in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(buf_id, ns_id, h.hl, h.line, h.col_start, h.col_end)
  end
  
  if cursor and win_id and vim.api.nvim_win_is_valid(win_id) then
    if cursor[1] > #lines then
      cursor[1] = #lines
    end
    pcall(vim.api.nvim_win_set_cursor, win_id, cursor)
  end
end

return M
