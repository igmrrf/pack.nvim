local state = require("pack.state")
local render = require("pack.ui.render")
local popup = require("pack.ui.popup")
local spinner_mod = require("pack.ui.spinner")

local M = {}

local win_id = nil
local buf_id = nil
local config_ref = nil
local plugin_map = {}
local ns_id = vim.api.nvim_create_namespace("pack")
local expanded_plugins = {}
local initial_focus = false

local selected_plugins = {}
local current_tab = "all"
local search_term = ""

local tabbar_mod = require("pack.ui.render.tabbar")
local TAB_ORDER = tabbar_mod.TAB_ORDER

function M.ensure_spinner()
	spinner_mod.ensure_spinner(buf_id, function()
		M.update()
	end)
end

local function next_tab(tab)
	for i, t in ipairs(TAB_ORDER) do
		if t == tab then
			return TAB_ORDER[(i % #TAB_ORDER) + 1]
		end
	end
	return TAB_ORDER[1]
end

function M.cycle_tab()
	current_tab = next_tab(current_tab)
	M.update({ jump_to_first = true })
end

function M.set_tab(index)
	if TAB_ORDER[index] then
		current_tab = TAB_ORDER[index]
		M.update({ jump_to_first = true })
	end
end

function M.filter()
	vim.ui.input({ prompt = "Filter Plugins: ", default = search_term }, function(input)
		if input ~= nil then
			search_term = input:lower()
			M.update({ jump_to_first = true })
		end
	end)
end

function M.open_popup(lines, opts)
	return popup.open_popup(lines, opts)
end

function M.show_help()
	return popup.show_help()
end

function M.show_profile()
	return popup.show_profile()
end

local function plugin_at_cursor(win)
	win = win or 0
	if not (buf_id and vim.api.nvim_buf_is_valid(buf_id)) then
		return nil
	end
	local cursor = vim.api.nvim_win_get_cursor(win)
	local line = cursor[1]
	return plugin_map[line]
end

function M.show_full_details()
	local p = plugin_at_cursor()
	return popup.show_full_details(p)
end

function M.show_log()
	local p = plugin_at_cursor()
	return popup.show_log(p)
end

function M.update_log()
	return popup.update_log()
end

function M.toggle_select()
	local p = plugin_at_cursor()
	if not p then
		return
	end
	if selected_plugins[p.name] then
		selected_plugins[p.name] = nil
	else
		selected_plugins[p.name] = true
	end
	M.update()
end

function M.clear_select()
	selected_plugins = {}
	M.update()
end

local actions_mod = require("pack.ui.actions")

function M.clean()
	return actions_mod.clean(M.update)
end

function M.uninstall()
	return actions_mod.uninstall(selected_plugins, plugin_at_cursor, function() selected_plugins = {} end, M.update)
end

function M.toggle_details()
	local p = plugin_at_cursor()
	if p then
		expanded_plugins[p.name] = not expanded_plugins[p.name]
		M.update()
	end
end

function M.toggle_disabled()
	return actions_mod.toggle_disabled(current_tab, selected_plugins, plugin_at_cursor, function() selected_plugins = {} end, M.update)
end

function M.update_one()
	return actions_mod.update_one(current_tab, selected_plugins, plugin_at_cursor, function() selected_plugins = {} end)
end

function M.update_all_outdated()
	return actions_mod.update_all_outdated(current_tab)
end

local window_mod = require("pack.ui.window")

function M.open(config)
	config_ref = config
	search_term = ""
	selected_plugins = {}
	pcall(function()
		state.reconcile_from_native(require("pack").native_pack)
	end)
	if win_id and vim.api.nvim_win_is_valid(win_id) then
		vim.api.nvim_set_current_win(win_id)
		return
	end

	current_tab = "all"
	expanded_plugins = {}

	buf_id, win_id = window_mod.create_window(config, function()
		M.update()
	end)

	initial_focus = true
	M.update()
	require("pack.async").check_all_outdated()
end

function M.update(opts)
	opts = opts or {}
	if not buf_id or not vim.api.nvim_buf_is_valid(buf_id) then
		return
	end

	local prev_plugin
	if win_id and vim.api.nvim_win_is_valid(win_id) then
		prev_plugin = plugin_at_cursor(win_id)
	end
	local prev_plugin_name = prev_plugin and prev_plugin.name or nil

	local cursor
	if win_id and vim.api.nvim_win_is_valid(win_id) then
		cursor = vim.api.nvim_win_get_cursor(win_id)
	end

	local lines = {}
	local highlights = {}
	plugin_map = {}

	local win_width = 80
	if win_id and vim.api.nvim_win_is_valid(win_id) then
		win_width = vim.api.nvim_win_get_width(win_id)
	end

	local help_str = "press g? for help"
	local help_pad = math.max(0, math.floor((win_width - #help_str) / 2))
	local help_line = string.rep(" ", help_pad) .. help_str

	table.insert(lines, help_line)
	table.insert(
		highlights,
		{ line = #lines - 1, col_start = help_pad, col_end = help_pad + #help_str, hl = "Comment" }
	)

	local status_line, is_active, status_pad = spinner_mod.get_status_line(win_width)
	if is_active then
		table.insert(lines, status_line)
		table.insert(highlights, { line = #lines - 1, col_start = status_pad, col_end = -1, hl = "DiagnosticWarn" })
	else
		table.insert(lines, "")
	end

	tabbar_mod.render_tab_bar(lines, highlights, current_tab)

	if current_tab == "all" then
		render.render_all_tab(lines, highlights, search_term, config_ref, expanded_plugins, selected_plugins, plugin_map)
	elseif current_tab == "outdated" then
		render.render_outdated_tab(lines, highlights, search_term, config_ref, expanded_plugins, selected_plugins, plugin_map)
	else
		render.render_disabled_tab(lines, highlights, search_term, config_ref, expanded_plugins, selected_plugins, plugin_map)
	end

	vim.bo[buf_id].modifiable = true
	vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, lines)
	vim.bo[buf_id].modifiable = false

	vim.api.nvim_buf_clear_namespace(buf_id, ns_id, 0, -1)
	for _, h in ipairs(highlights) do
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
		if prev_plugin_name and not (initial_focus or opts.jump_to_first) then
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
		elseif initial_focus or opts.jump_to_first then
			for i = 1, #lines do
				if plugin_map[i] then
					cursor[1] = i
					break
				end
			end
		end
		initial_focus = false

		if cursor[1] > #lines then
			cursor[1] = #lines
		end
		if cursor[1] < 1 then
			cursor[1] = 1
		end
		pcall(vim.api.nvim_win_set_cursor, win_id, cursor)
	end

	M.update_log()
end

return M
