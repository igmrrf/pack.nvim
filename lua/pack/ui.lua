local state = require("pack.state")
local render = require("pack.ui.render")
local popup = require("pack.ui.popup")
local spinner_mod = require("pack.ui.spinner")
local actions_mod = require("pack.ui.actions")

local M = {}

local win_id = nil
local buf_id = nil
local config_ref = nil
local plugin_map = {}
local ns_id = vim.api.nvim_create_namespace("pack")
local expanded_plugins = {}
local auto_expanded = {}
local initial_focus = false
local was_installing = false
local auto_opened_for_install = false

local selected_plugins = {}
local current_tab = "all"
local search_term = ""
local show_select_ui = false

local tabbar_mod = require("pack.ui.render.tabbar")
local TAB_ORDER = tabbar_mod.TAB_ORDER

function M.close()
	if win_id and vim.api.nvim_win_is_valid(win_id) then
		pcall(vim.api.nvim_win_close, win_id, true)
		win_id = nil
		buf_id = nil
	end
	spinner_mod.stop_spinner()
	-- Proactively tear down the dashboard's own augroups and the streaming log
	-- view rather than relying on their lazy self-deletion (resize augroup on the
	-- next VimResized, log timer on its next tick).
	pcall(vim.api.nvim_del_augroup_by_name, "pack_ui_resize")
	pcall(vim.api.nvim_del_augroup_by_name, "pack_ui_startup_focus")
	pcall(popup.stop_log_view)
end

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

local function prev_tab(tab)
	for i, t in ipairs(TAB_ORDER) do
		if t == tab then
			local prev_idx = i - 1
			if prev_idx < 1 then
				prev_idx = #TAB_ORDER
			end
			return TAB_ORDER[prev_idx]
		end
	end
	return TAB_ORDER[#TAB_ORDER]
end

local function on_tab_change()
	if current_tab == "outdated" then
		require("pack.async").check_all_outdated()
	end
end

function M.cycle_tab()
	current_tab = next_tab(current_tab)
	on_tab_change()
	M.update({ jump_to_first = true })
end

function M.cycle_tab_back()
	current_tab = prev_tab(current_tab)
	on_tab_change()
	M.update({ jump_to_first = true })
end

function M.set_tab(index)
	if TAB_ORDER[index] then
		current_tab = TAB_ORDER[index]
		on_tab_change()
		M.update({ jump_to_first = true })
	end
end

function M.filter()
	local filter_type = (config_ref and config_ref.ui and config_ref.ui.filter) or "default"
	local prompt = "Filter Plugins: "
	local function set_search(input)
		if input ~= nil then
			search_term = input:lower()
			M.update({ jump_to_first = true })
		end
	end

	if type(filter_type) == "function" then
		filter_type({ prompt = prompt, default = search_term }, set_search)
	elseif filter_type == "input" then
		local ok, input = pcall(vim.fn.input, prompt, search_term)
		if ok then
			set_search(input)
		end
	else
		vim.ui.input({ prompt = prompt, default = search_term }, set_search)
	end
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
	return popup.show_full_details(p, current_tab)
end

function M.show_log()
	local p = plugin_at_cursor()
	return popup.show_log(p)
end

function M.update_log()
	return popup.update_log()
end

function M.sync_one()
	return actions_mod.sync_one(selected_plugins, plugin_at_cursor, function() selected_plugins = {} end, M.update)
end

function M.delete_one()
	return actions_mod.delete_one(selected_plugins, plugin_at_cursor, function() selected_plugins = {} end, M.update)
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
		show_select_ui = true
	end
	M.update()
end

function M.toggle_select_ui()
	if next(selected_plugins) ~= nil then
		selected_plugins = {}
		show_select_ui = true
	else
		show_select_ui = not show_select_ui
	end
	M.update()
end

function M.clear_select()
	selected_plugins = {}
	M.update()
end

function M.clean()
	return actions_mod.clean(M.update)
end

function M.uninstall()
	return actions_mod.uninstall(selected_plugins, plugin_at_cursor, function() selected_plugins = {} end, M.update)
end

function M.delete_all_disabled()
	return actions_mod.delete_all_disabled(function() selected_plugins = {} end, M.update)
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

function M.open(config, opts)
	opts = opts or {}
	config_ref = config
	search_term = ""
	selected_plugins = {}
	show_select_ui = false
	pcall(function()
		state.reconcile_from_native(require("pack").native_pack)
	end)
	if win_id and vim.api.nvim_win_is_valid(win_id) then
		vim.api.nvim_set_current_win(win_id)
		return
	end

	auto_opened_for_install = (opts.auto_opened == true)
	current_tab = "all"
	expanded_plugins = {}
	auto_expanded = {}

	buf_id, win_id = window_mod.create_window(config, function()
		M.update()
	end)

	initial_focus = true
	M.update()
	vim.schedule(function()
		require("pack.async").check_all_outdated()
	end)
end

function M.update(opts)
	opts = opts or {}
	if not buf_id or not vim.api.nvim_buf_is_valid(buf_id) then
		return
	end

	local prev_plugin
	local prev_line
	local prev_header_line
	if win_id and vim.api.nvim_win_is_valid(win_id) then
		prev_line = vim.api.nvim_win_get_cursor(win_id)[1]
		prev_plugin = plugin_map[prev_line]
		if prev_plugin then
			for i = prev_line, 1, -1 do
				if plugin_map[i] and plugin_map[i].name == prev_plugin.name then
					prev_header_line = i
				else
					break
				end
			end
		end
	end
	local prev_plugin_name = prev_plugin and prev_plugin.name or nil
	local prev_offset = (prev_line and prev_header_line) and (prev_line - prev_header_line) or 0

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

	tabbar_mod.render_quick_help(lines, highlights, current_tab, win_width)

	local status_line, is_active, status_pad = spinner_mod.get_status_line(win_width)
	if is_active then
		table.insert(lines, status_line)
		table.insert(highlights, { line = #lines - 1, col_start = status_pad, col_end = -1, hl = "DiagnosticWarn" })
	else
		table.insert(lines, "")
	end

	local just_finished_install = was_installing and not is_active
	was_installing = is_active

	if just_finished_install and auto_opened_for_install then
		auto_opened_for_install = false
		vim.schedule(function()
			M.close()
		end)
	end

	tabbar_mod.render_tab_bar(lines, highlights, current_tab)

	for _, p in pairs(state.get_plugins()) do
		local is_busy = (p.status == "building" or p.status == "installing" or p.status == "updating")
		if is_busy and expanded_plugins[p.name] == nil then
			expanded_plugins[p.name] = true
			auto_expanded[p.name] = true
		elseif not is_busy and auto_expanded[p.name] then
			auto_expanded[p.name] = nil
			expanded_plugins[p.name] = nil
		end
	end

	if current_tab == "all" then
		render.render_all_tab(lines, highlights, search_term, config_ref, expanded_plugins, selected_plugins, plugin_map, show_select_ui)
	elseif current_tab == "outdated" then
		render.render_outdated_tab(lines, highlights, search_term, config_ref, expanded_plugins, selected_plugins, plugin_map, show_select_ui)
	else
		render.render_disabled_tab(lines, highlights, search_term, config_ref, expanded_plugins, selected_plugins, plugin_map, show_select_ui)
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
		pcall(vim.api.nvim_buf_add_highlight, buf_id, ns_id, h.hl, h.line, h.col_start, end_col)
	end

	if cursor and win_id and vim.api.nvim_win_is_valid(win_id) then
		local should_jump = initial_focus or opts.jump_to_first

		if should_jump then
			local placed = false
			for i = 1, #lines do
				if plugin_map[i] then
					cursor[1] = i
					placed = true
					break
				end
			end
			if not placed then
				cursor[1] = 1
			end
		else
			-- Re-anchor onto the same plugin the cursor was on before the refresh:
			-- an async status change above it (a plugin finishing/collapsing, an
			-- inline log growing) shifts its row, and clamping the raw line number
			-- would silently land the cursor on a different plugin.
			local reanchored = false
			if prev_plugin_name then
				local new_header_line
				local new_last_line
				for i = 1, #lines do
					if plugin_map[i] and plugin_map[i].name == prev_plugin_name then
						if not new_header_line then
							new_header_line = i
						end
						new_last_line = i
					end
				end
				if new_header_line then
					local target = new_header_line + prev_offset
					if target <= new_last_line then
						cursor[1] = target
					else
						cursor[1] = new_last_line
					end
					reanchored = true
				end
			end
			if not reanchored then
				if cursor[1] > #lines then
					cursor[1] = math.max(1, #lines)
				end
				if cursor[1] < 1 then
					cursor[1] = 1
				end
			end
		end

		pcall(vim.api.nvim_win_set_cursor, win_id, cursor)
		if should_jump then
			pcall(vim.api.nvim_win_call, win_id, function()
				vim.cmd("normal! zt")
			end)
		end
		if initial_focus then
			initial_focus = false
		end
	end

	M.update_log()
end

return M
