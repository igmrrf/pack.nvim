local state = require("pack.state")

local M = {}

local win_id = nil
local buf_id = nil
local config_ref = nil
local plugin_map = {}
local ns_id = vim.api.nvim_create_namespace("pack")
local expanded_plugins = {}

local current_tab = "all"
local TAB_ORDER = { "all", "outdated", "disabled" }
local search_term = ""

local function next_tab(tab)
  for i, t in ipairs(TAB_ORDER) do
    if t == tab then
      return TAB_ORDER[(i % #TAB_ORDER) + 1]
    end
  end
  return TAB_ORDER[1]
end

local FOOTER_BY_TAB = {
  all = "",
  outdated = "",
  disabled = "",
}

function M.cycle_tab()
  current_tab = next_tab(current_tab)
  M.update()
end

function M.set_tab(index)
  if TAB_ORDER[index] then
    current_tab = TAB_ORDER[index]
    M.update()
  end
end

function M.filter()
  vim.ui.input({ prompt = "Filter Plugins: ", default = search_term }, function(input)
    if input ~= nil then
      search_term = input:lower()
      M.update()
    end
  end)
end

local KEYMAP_HELP = {
  { key = "q", scope = "all", desc = "close" },
  { key = "g?", scope = "all", desc = "show this help" },
  { key = "S", scope = "all", desc = "sync all (install missing, pull updates)" },
  { key = "Tab", scope = "all", desc = "cycle tabs" },
  { key = "1/2/3", scope = "all", desc = "go to tab 1/2/3 directly" },
  { key = "Enter", scope = "all", desc = "toggle inline details for plugin" },
  { key = "K", scope = "all", desc = "full details (commit info) in popup" },
  { key = "l", scope = "all", desc = "view install/update logs" },
  { key = "x", scope = "All, Disabled", desc = "toggle disable/enable" },
  { key = "c", scope = "all", desc = "check for outdated plugins" },
  { key = "u", scope = "Outdated", desc = "update plugin" },
  { key = "U", scope = "Outdated", desc = "update all outdated plugins" },
  { key = "/", scope = "all", desc = "filter plugins" },
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

  for _, key in ipairs(opts.close_keys or { "q", "<Esc>" }) do
    vim.keymap.set("n", key, "<Cmd>close<CR>", { buffer = buf, noremap = true, silent = true })
  end

  return buf, win
end

function M.show_help()
  local lines = { "  Pack Keymaps", "  ==============", "" }
  for _, entry in ipairs(KEYMAP_HELP) do
    table.insert(lines, string.format("  %-7s %-14s %s", entry.key, entry.scope, entry.desc))
  end
  open_popup(lines, { close_keys = { "q", "g?", "<Esc>" } })
end

local function plugin_at_cursor()
  local cursor = vim.api.nvim_win_get_cursor(0)
  return plugin_map[cursor[1]]
end

function M.toggle_details()
  local p = plugin_at_cursor()
  if not p then return end
  expanded_plugins[p.name] = not expanded_plugins[p.name]
  M.update()
end

local function trigger_summary(p)
  local parts = {}
  if p.cmd then table.insert(parts, "cmd=" .. vim.inspect(p.cmd)) end
  if p.event then table.insert(parts, "event=" .. vim.inspect(p.event)) end
  if p.ft then table.insert(parts, "ft=" .. vim.inspect(p.ft)) end
  if p.keys then table.insert(parts, "keys=" .. vim.inspect(p.keys)) end
  if #parts == 0 then return "none" end
  return table.concat(parts, ", ")
end

local function quick_detail_lines(p)
  return {
    "url:      " .. p.url,
    "status:   " .. p.status,
    "dir:      " .. p.dir,
    "lazy:     " .. tostring(p.lazy),
    "trigger:  " .. trigger_summary(p),
    "disabled: " .. tostring(p.disabled),
  }
end

function M.show_full_details()
  local p = plugin_at_cursor()
  if not p then return end

  local lines = { "  " .. p.name, "  " .. string.rep("=", #p.name), "" }
  for _, dl in ipairs(quick_detail_lines(p)) do
    table.insert(lines, "  " .. dl)
  end

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
  if not p then return end

  local new_disabled = not p.disabled
  state.set_disabled(p.name, new_disabled)

  if new_disabled then
    if p.status == "loaded" then
      vim.notify("pack: '" .. p.name .. "' disabled but already loaded - restart Neovim to fully unload it", vim.log.levels.WARN)
    else
      require("pack.loader").remove_triggers(p)
    end
  else
    require("pack.loader").enable(p)
  end
  M.update()
end

function M.update_one()
  if current_tab ~= "outdated" then return end
  local p = plugin_at_cursor()
  if p then require("pack.async").update_plugin(p) end
end

function M.update_all_outdated()
  if current_tab ~= "outdated" then return end
  for _, p in pairs(state.get_plugins()) do
    if not p.disabled and p.behind and p.behind > 0 then
      require("pack.async").update_plugin(p)
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
  expanded_plugins = {}

  buf_id = vim.api.nvim_create_buf(false, true)
  vim.bo[buf_id].bufhidden = "wipe"
  vim.bo[buf_id].buftype = "nofile"
  vim.bo[buf_id].swapfile = false
  vim.bo[buf_id].filetype = "pack"
  
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
  
  local opts = { buffer = buf_id, noremap = true, silent = true }
  vim.keymap.set("n", "q", "<Cmd>close<CR>", opts)
  vim.keymap.set("n", "g?", "<Cmd>lua require('pack.ui').show_help()<CR>", opts)
  vim.keymap.set("n", "S", "<Cmd>Pack sync<CR>", opts)
  vim.keymap.set("n", "<CR>", "<Cmd>lua require('pack.ui').toggle_details()<CR>", opts)
  vim.keymap.set("n", "K", "<Cmd>lua require('pack.ui').show_full_details()<CR>", opts)
  vim.keymap.set("n", "l", "<Cmd>lua require('pack.ui').show_log()<CR>", opts)
  vim.keymap.set("n", "<Tab>", "<Cmd>lua require('pack.ui').cycle_tab()<CR>", opts)
  vim.keymap.set("n", "x", "<Cmd>lua require('pack.ui').toggle_disabled()<CR>", opts)
  vim.keymap.set("n", "c", "<Cmd>lua require('pack.async').check_all_outdated()<CR>", opts)
  vim.keymap.set("n", "u", "<Cmd>lua require('pack.ui').update_one()<CR>", opts)
  vim.keymap.set("n", "U", "<Cmd>lua require('pack.ui').update_all_outdated()<CR>", opts)
  vim.keymap.set("n", "/", "<Cmd>lua require('pack.ui').filter()<CR>", opts)
  vim.keymap.set("n", "1", "<Cmd>lua require('pack.ui').set_tab(1)<CR>", opts)
  vim.keymap.set("n", "2", "<Cmd>lua require('pack.ui').set_tab(2)<CR>", opts)
  vim.keymap.set("n", "3", "<Cmd>lua require('pack.ui').set_tab(3)<CR>", opts)

  M.update()
  require("pack.async").check_all_outdated()
end

function M.show_log()
  local p = plugin_at_cursor()
  if not p or not p.log or #p.log == 0 then
    vim.notify("No logs available for this item.", vim.log.levels.INFO)
    return
  end
  local buf = open_popup(p.log, { wrap = true })
  vim.bo[buf].filetype = "pack_log"
end

local function add_plugin_details(p, lines, highlights, indent)
  if expanded_plugins[p.name] then
    local detail_lines = quick_detail_lines(p)
    for _, dline in ipairs(detail_lines) do
      table.insert(lines, indent .. dline)
      plugin_map[#lines] = p
      table.insert(highlights, { line = #lines - 1, col_start = #indent, col_end = -1, hl = "Comment" })
    end
  end
end

local function render_all_tab(lines, highlights)
  local plugins = state.get_plugins()
  local groups = { loaded = {}, installed = {}, missing = {}, installing = {}, updating = {}, error = {} }

  for _, p in pairs(plugins) do
    if not p.disabled then
      if search_term == "" or p.name:lower():match(search_term) then
        if groups[p.status] then table.insert(groups[p.status], p)
        else table.insert(groups.installed, p) end
      end
    end
  end

  for _, list in pairs(groups) do table.sort(list, function(a, b) return a.name < b.name end) end

  local function render_group(name, list, icon, hl_group)
    if #list > 0 then
      table.insert(lines, "  " .. name .. " (" .. #list .. ")")
      table.insert(highlights, { line = #lines - 1, col_start = 2, col_end = -1, hl = "Title" })
      for _, p in ipairs(list) do
        local expand_icon = expanded_plugins[p.name] and "▼" or "▶"
        local line = string.format("    %s %s %s", expand_icon, icon, p.name)
        table.insert(lines, line)
        plugin_map[#lines] = p
        
        table.insert(highlights, { line = #lines - 1, col_start = 4, col_end = 7, hl = "Comment" })
        local icon_start = 8
        local icon_end = 8 + #icon
        table.insert(highlights, { line = #lines - 1, col_start = icon_start, col_end = icon_end, hl = hl_group })
        
        add_plugin_details(p, lines, highlights, "      ")
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

local function render_outdated_tab(lines, highlights)
  local outdated = {}
  for _, p in pairs(state.get_plugins()) do
    if not p.disabled and p.behind and p.behind > 0 then
      if search_term == "" or p.name:lower():match(search_term) then
        table.insert(outdated, p)
      end
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
    local expand_icon = expanded_plugins[p.name] and "▼" or "▶"
    table.insert(lines, string.format("    %s %s %s — %d behind", expand_icon, config_ref.ui.icons.sync, p.name, p.behind))
    plugin_map[#lines] = p
    table.insert(highlights, { line = #lines - 1, col_start = 4, col_end = 7, hl = "Comment" })
    table.insert(highlights, { line = #lines - 1, col_start = 8, col_end = 8 + #config_ref.ui.icons.sync, hl = "DiagnosticWarn" })
    
    if expanded_plugins[p.name] then
      local branch_suffix = p.upstream_branch and (" (" .. p.upstream_branch .. ")") or ""
      table.insert(lines, "      Path:            " .. p.dir)
      plugin_map[#lines] = p
      table.insert(lines, "      Source:          " .. p.url)
      plugin_map[#lines] = p
      table.insert(lines, "      Revision before: " .. (p.revision_before or "?"))
      plugin_map[#lines] = p
      table.insert(lines, "      Revision after:  " .. (p.revision_after or "?") .. branch_suffix)
      plugin_map[#lines] = p
      
      if p.pending_commits and #p.pending_commits > 0 then
        table.insert(lines, "")
        plugin_map[#lines] = p
        table.insert(lines, "      Pending updates:")
        plugin_map[#lines] = p
        for _, commit in ipairs(p.pending_commits) do
          table.insert(lines, "      > " .. commit)
          plugin_map[#lines] = p
          table.insert(highlights, { line = #lines - 1, col_start = 6, col_end = -1, hl = "Comment" })
        end
      end
    end
  end
end

local function render_disabled_tab(lines, highlights)
  local disabled = {}
  for _, p in pairs(state.get_plugins()) do
    if p.disabled then
      if search_term == "" or p.name:lower():match(search_term) then
        table.insert(disabled, p)
      end
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
    local expand_icon = expanded_plugins[p.name] and "▼" or "▶"
    table.insert(lines, string.format("    %s %s (%s)", expand_icon, p.name, p.status))
    plugin_map[#lines] = p
    table.insert(highlights, { line = #lines - 1, col_start = 4, col_end = 7, hl = "Comment" })
    add_plugin_details(p, lines, highlights, "      ")
  end
end

function M.update()
  if not buf_id or not vim.api.nvim_buf_is_valid(buf_id) then return end

  local prev_plugin = plugin_at_cursor()
  local prev_plugin_name = prev_plugin and prev_plugin.name or nil

  local cursor
  if win_id and vim.api.nvim_win_is_valid(win_id) then
    cursor = vim.api.nvim_win_get_cursor(win_id)
  end

  local lines = {}
  local highlights = {}
  plugin_map = {}

  -- Header
  local win_width = 80
  if win_id and vim.api.nvim_win_is_valid(win_id) then
    win_width = vim.api.nvim_win_get_width(win_id)
  end

  local title_str = " Pack.nvim "
  local title_pad = math.max(0, math.floor((win_width - #title_str) / 2))
  local title_line = string.rep(" ", title_pad) .. title_str

  local help_str = "press g? for help"
  local help_pad = math.max(0, math.floor((win_width - #help_str) / 2))
  local help_line = string.rep(" ", help_pad) .. help_str

  table.insert(lines, title_line)
  table.insert(highlights, { line = #lines - 1, col_start = title_pad, col_end = title_pad + #title_str, hl = "Search" })
  table.insert(lines, help_line)
  table.insert(highlights, { line = #lines - 1, col_start = help_pad, col_end = help_pad + #help_str, hl = "Comment" })
  table.insert(lines, "")

  -- Render Tab Bar
  local tab_line = "  "
  for i, tab in ipairs(TAB_ORDER) do
    local is_active = (tab == current_tab)
    local tab_text = string.format(" %d %s ", i, tab:sub(1,1):upper() .. tab:sub(2))
    
    local start_col = #tab_line
    tab_line = tab_line .. tab_text
    local end_col = #tab_line
    
    if is_active then
      table.insert(highlights, { line = #lines, col_start = start_col, col_end = end_col, hl = "TabLineSel" })
    else
      table.insert(highlights, { line = #lines, col_start = start_col, col_end = end_col, hl = "TabLine" })
    end
    tab_line = tab_line .. "  "
  end
  
  table.insert(lines, tab_line)
  table.insert(lines, "")

  if current_tab == "all" then
    render_all_tab(lines, highlights)
  elseif current_tab == "outdated" then
    render_outdated_tab(lines, highlights)
  else
    render_disabled_tab(lines, highlights)
  end

  vim.bo[buf_id].modifiable = true
  vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, lines)
  vim.bo[buf_id].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf_id, ns_id, 0, -1)
  for _, h in ipairs(highlights) do
    -- col_end == -1 means "to end of line"; extmarks need an explicit end_col.
    local end_col = h.col_end
    if end_col == -1 then
      local line_text = lines[h.line + 1]
      end_col = line_text and #line_text or h.col_start
    end
    pcall(vim.api.nvim_buf_set_extmark, buf_id, ns_id, h.line, h.col_start, {
      end_col = end_col,
      hl_group = h.hl,
    })
  end

  if cursor and win_id and vim.api.nvim_win_is_valid(win_id) then
    -- Attempt to retain cursor position on the exact plugin line
    if prev_plugin_name then
      local found_line = nil
      for i = 1, #lines do
        local p = plugin_map[i]
        if p and p.name == prev_plugin_name then
          found_line = i
          break
        end
      end
      if found_line then
        cursor[1] = found_line
      end
    end

    if cursor[1] > #lines then cursor[1] = #lines end
    if cursor[1] < 1 then cursor[1] = 1 end
    pcall(vim.api.nvim_win_set_cursor, win_id, cursor)
  end
end

return M
