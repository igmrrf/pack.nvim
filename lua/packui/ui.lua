local state = require("packui.state")

local M = {}

local win_id = nil
local buf_id = nil
local config_ref = nil
local plugin_map = {}
local ns_id = vim.api.nvim_create_namespace("packui")

local current_tab = "all"
local TAB_ORDER = { "all", "outdated", "disabled" }

local function next_tab(tab)
  for i, t in ipairs(TAB_ORDER) do
    if t == tab then
      return TAB_ORDER[(i % #TAB_ORDER) + 1]
    end
  end
  return TAB_ORDER[1]
end

local FOOTER_BY_TAB = {
  all = "  [S]ync  [x]disable  [Tab]next tab  [?]help  [q]uit",
  outdated = "  [u]pdate one  [U]pdate all  [c]heck  [Tab]next tab  [?]help  [q]uit",
  disabled = "  [x]enable  [Tab]next tab  [?]help  [q]uit",
}

function M.cycle_tab()
  current_tab = next_tab(current_tab)
  M.update()
end

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

local function plugin_at_cursor()
  local cursor = vim.api.nvim_win_get_cursor(0)
  return plugin_map[cursor[1]]
end

local function trigger_summary(p)
  local parts = {}
  if p.cmd then table.insert(parts, "cmd=" .. vim.inspect(p.cmd)) end
  if p.event then table.insert(parts, "event=" .. vim.inspect(p.event)) end
  if p.ft then table.insert(parts, "ft=" .. vim.inspect(p.ft)) end
  if p.keys then table.insert(parts, "keys=" .. vim.inspect(p.keys)) end
  if #parts == 0 then
    return "none"
  end
  return table.concat(parts, ", ")
end

local function quick_detail_lines(p)
  return {
    "  " .. p.name,
    "  " .. string.rep("=", #p.name),
    "",
    "  url:      " .. p.url,
    "  status:   " .. p.status,
    "  dir:      " .. p.dir,
    "  lazy:     " .. tostring(p.lazy),
    "  trigger:  " .. trigger_summary(p),
    "  disabled: " .. tostring(p.disabled),
  }
end

function M.show_details()
  local p = plugin_at_cursor()
  if not p then
    return
  end
  open_popup(quick_detail_lines(p), { height_pct = 0.4 })
end

function M.show_full_details()
  local p = plugin_at_cursor()
  if not p then
    return
  end

  local lines = quick_detail_lines(p)

  local commit_line = "(no commit info available)"
  if vim.fn.isdirectory(p.dir .. "/.git") == 1 then
    local result = vim.fn.system({ "git", "-C", p.dir, "log", "-1", "--format=%h %s" })
    if vim.v.shell_error == 0 and result ~= "" then
      commit_line = vim.trim(result)
    end
  end
  table.insert(lines, "  commit:   " .. commit_line)

  if p.behind ~= nil then
    table.insert(lines, "  behind:   " .. tostring(p.behind) .. " commit(s)")
  else
    table.insert(lines, "  behind:   not checked")
  end

  open_popup(lines, { height_pct = 0.5 })
end

function M.toggle_disabled()
  local p = plugin_at_cursor()
  if not p then
    return
  end

  local new_disabled = not p.disabled
  state.set_disabled(p.name, new_disabled)

  if new_disabled then
    if p.status == "loaded" then
      vim.notify(
        "packui: '" .. p.name .. "' disabled but already loaded - restart Neovim to fully unload it",
        vim.log.levels.WARN
      )
    else
      require("packui.loader").remove_triggers(p)
    end
  else
    require("packui.loader").enable(p)
  end

  M.update()
end

function M.update_one()
  if current_tab ~= "outdated" then
    return
  end
  local p = plugin_at_cursor()
  if not p then
    return
  end
  require("packui.async").update_plugin(p)
end

function M.update_all_outdated()
  if current_tab ~= "outdated" then
    return
  end
  for _, p in pairs(state.get_plugins()) do
    if not p.disabled and p.behind and p.behind > 0 then
      require("packui.async").update_plugin(p)
    end
  end
end

function M.open(config)
  config_ref = config
  if win_id and vim.api.nvim_win_is_valid(win_id) then
    vim.api.nvim_set_current_win(win_id)
    return
  end
  
  current_tab = "all"

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
  vim.api.nvim_buf_set_keymap(buf_id, "n", "<CR>", "<Cmd>lua require('packui.ui').show_details()<CR>", opts)
  vim.api.nvim_buf_set_keymap(buf_id, "n", "K", "<Cmd>lua require('packui.ui').show_full_details()<CR>", opts)
  vim.api.nvim_buf_set_keymap(buf_id, "n", "l", "<Cmd>lua require('packui.ui').show_log()<CR>", opts)
  vim.api.nvim_buf_set_keymap(buf_id, "n", "<Tab>", "<Cmd>lua require('packui.ui').cycle_tab()<CR>", opts)
  vim.api.nvim_buf_set_keymap(buf_id, "n", "x", "<Cmd>lua require('packui.ui').toggle_disabled()<CR>", opts)
  vim.api.nvim_buf_set_keymap(buf_id, "n", "c", "<Cmd>lua require('packui.async').check_all_outdated()<CR>", opts)
  vim.api.nvim_buf_set_keymap(buf_id, "n", "u", "<Cmd>lua require('packui.ui').update_one()<CR>", opts)
  vim.api.nvim_buf_set_keymap(buf_id, "n", "U", "<Cmd>lua require('packui.ui').update_all_outdated()<CR>", opts)

  M.update()
  require("packui.async").check_all_outdated()
end

function M.show_log()
  local p = plugin_at_cursor()
  if not p or not p.log or #p.log == 0 then
    vim.notify("No logs available for this item.", vim.log.levels.INFO)
    return
  end
  local buf = open_popup(p.log, { wrap = true })
  vim.bo[buf].filetype = "packui_log"
end

local function render_all_tab(lines, highlights)
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
    if not p.disabled then
      if groups[p.status] then
        table.insert(groups[p.status], p)
      else
        table.insert(groups.installed, p)
      end
    end
  end

  for _, list in pairs(groups) do
    table.sort(list, function(a, b) return a.name < b.name end)
  end

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
end

local function outdated_plugin_lines(p)
  if not p.pending_commits or #p.pending_commits == 0 then
    return {
      string.format("  ## %s — %d behind (press c to re-check)", p.name, p.behind),
      "",
    }
  end

  local branch_suffix = p.upstream_branch and (" (" .. p.upstream_branch .. ")") or ""
  local lines = {
    "  ## " .. p.name,
    "  Path:            " .. p.dir,
    "  Source:          " .. p.url,
    "  Revision before: " .. (p.revision_before or "?"),
    "  Revision after:  " .. (p.revision_after or "?") .. branch_suffix,
    "",
    "  Pending updates:",
  }
  for _, commit in ipairs(p.pending_commits) do
    table.insert(lines, "  > " .. commit)
  end
  table.insert(lines, "")
  return lines
end

local function render_outdated_tab(lines, highlights)
  local outdated = {}
  for _, p in pairs(state.get_plugins()) do
    if not p.disabled and p.behind and p.behind > 0 then
      table.insert(outdated, p)
    end
  end
  table.sort(outdated, function(a, b) return a.name < b.name end)

  if #outdated == 0 then
    table.insert(lines, "  No outdated plugins (press c to check)")
    return
  end

  table.insert(lines, "  Outdated (" .. #outdated .. ")")
  table.insert(highlights, { line = #lines - 1, col_start = 2, col_end = -1, hl = "Title" })
  table.insert(lines, "")

  for _, p in ipairs(outdated) do
    local header_line = #lines
    for _, line in ipairs(outdated_plugin_lines(p)) do
      table.insert(lines, line)
      plugin_map[#lines] = p
    end
    table.insert(highlights, { line = header_line, col_start = 2, col_end = -1, hl = "Title" })
  end
end

local function render_disabled_tab(lines, highlights)
  local disabled = {}
  for _, p in pairs(state.get_plugins()) do
    if p.disabled then
      table.insert(disabled, p)
    end
  end
  table.sort(disabled, function(a, b) return a.name < b.name end)

  if #disabled == 0 then
    table.insert(lines, "  No disabled plugins")
    return
  end

  table.insert(lines, "  Disabled (" .. #disabled .. ")")
  table.insert(highlights, { line = #lines - 1, col_start = 2, col_end = -1, hl = "Title" })
  for _, p in ipairs(disabled) do
    table.insert(lines, string.format("    %s (%s)", p.name, p.status))
    plugin_map[#lines] = p
  end
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
  local highlights = {}
  plugin_map = {}

  table.insert(lines, "  Pack UI Dashboard [" .. current_tab .. "]")
  table.insert(lines, "  =================")
  table.insert(lines, "")

  if current_tab == "all" then
    render_all_tab(lines, highlights)
  elseif current_tab == "outdated" then
    render_outdated_tab(lines, highlights)
  else
    render_disabled_tab(lines, highlights)
  end

  table.insert(lines, FOOTER_BY_TAB[current_tab] or FOOTER_BY_TAB.all)
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
