local state = require("pack.state")

local M = {}

local win_id = nil
local buf_id = nil
local config_ref = nil
local plugin_map = {}
local ns_id = vim.api.nvim_create_namespace("pack")
local expanded_plugins = {}

local selected_plugins = {}

local current_tab = "all"
local TAB_ORDER = { "all", "outdated", "disabled" }
local TAB_LABELS = {
	all = "Plugins",
	outdated = "Updates",
	disabled = "Disabled",
}
local search_term = ""

-- Single dashboard-wide loading spinner. A repeating timer advances the frame
-- and repaints while any task is in-flight, then stops itself. All async work
-- (outdated checks, updates, installs) shares this one animation rather than
-- each spinning on its own.
local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local spinner_idx = 1
local spinner_timer = nil

-- Is there any work worth animating? Deterministic busy checks OR a plugin
-- mid-install/update. Self-correcting: statuses reset on completion.
local open_popup = function(lines, opts)
	return M.open_popup(lines, opts)
end

local function work_in_progress()
	if package.loaded["pack.async"] and require("pack.async").is_busy() then
		return true
	end
	for _, p in pairs(state.get_plugins()) do
		if p.status == "updating" or p.status == "installing" or p.status == "building" then
			return true
		end
	end
	return false
end

local function stop_spinner()
	if spinner_timer then
		pcall(vim.fn.timer_stop, spinner_timer)
		spinner_timer = nil
	end
end

-- Start the spinner timer if it isn't already running and the dashboard is open.
function M.ensure_spinner()
	if spinner_timer then
		return
	end
	if not (buf_id and vim.api.nvim_buf_is_valid(buf_id)) then
		return
	end
	spinner_timer = vim.fn.timer_start(100, function()
		-- Dashboard closed or work done: stop and do a final clean repaint.
		if not (buf_id and vim.api.nvim_buf_is_valid(buf_id)) or not work_in_progress() then
			stop_spinner()
			M.update()
			return
		end
		spinner_idx = (spinner_idx % #SPINNER_FRAMES) + 1
		M.update()
		-- Native vim.pack.update() blocks the main loop in vim.wait(): our timer
		-- still fires and repaints the buffer, but Neovim won't flush the screen
		-- until the wait yields. Force a redraw so the spinner actually animates
		-- while an update is in flight (native does the same for its own progress).
		for _, p in pairs(state.get_plugins()) do
			if p.status == "updating" then
				pcall(vim.cmd, "redraw")
				break
			end
		end
	end, { ["repeat"] = -1 })
end

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
	{ key = "q", scope = "all", desc = "close dashboard" },
	{ key = "g?", scope = "all", desc = "show this help popup" },
	{ key = "S", scope = "all", desc = "sync all (install missing, pull updates)" },
	{ key = "C", scope = "all", desc = "clean unused plugins (no longer in spec)" },
	{ key = "X", scope = "all", desc = "uninstall cursor/selected plugin from disk" },
	{ key = "<Space>", scope = "all", desc = "toggle selection for bulk action" },
	{ key = "v", scope = "all", desc = "clear all selections" },
	{ key = "Tab", scope = "all", desc = "cycle tabs" },
	{ key = "1/2/3", scope = "all", desc = "go to tab 1/2/3 directly" },
	{ key = "Enter", scope = "all", desc = "toggle inline details for plugin" },
	{ key = "K", scope = "all", desc = "full details (commit info) in popup" },
	{ key = "l", scope = "all", desc = "view install/update logs" },
	{ key = "p", scope = "all", desc = "show startup profile (load times & bar chart)" },
	{ key = "d", scope = "all", desc = "view pending updates diff" },
	{ key = "x", scope = "Plugins, Disabled", desc = "toggle disable/enable (cursor/selected)" },
	{ key = "c", scope = "all", desc = "check for outdated plugins" },
	{ key = "u", scope = "Updates", desc = "update cursor/selected plugin" },
	{ key = "U", scope = "Updates", desc = "update all outdated plugins" },
	{ key = "/", scope = "all", desc = "filter plugins (name, cat:category, tag:tag)" },
}

function M.open_popup(lines, opts)
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
		style = "minimal",
	})
	vim.wo[win].wrap = opts.wrap or false

	for _, key in ipairs(opts.close_keys or { "q", "<Esc>" }) do
		vim.keymap.set("n", key, "<Cmd>close<CR>", { buffer = buf, noremap = true, silent = true })
	end

	-- Own the resize handler in a per-popup augroup and tear it down when the
	-- popup window closes. The previous ungrouped autocmd only self-deleted if a
	-- VimResized happened to fire while the window was invalid, so opening and
	-- closing popups without resizing leaked one live autocmd apiece.
	local popup_group = vim.api.nvim_create_augroup("pack_popup_" .. buf, { clear = true })
	vim.api.nvim_create_autocmd("VimResized", {
		group = popup_group,
		callback = function()
			if not vim.api.nvim_win_is_valid(win) then
				return
			end
			local w = math.floor(vim.o.columns * (opts.width_pct or 0.6))
			local h = math.min(#lines + 2, math.floor(vim.o.lines * (opts.height_pct or 0.6)))
			vim.api.nvim_win_set_config(win, {
				relative = "editor",
				width = w,
				height = h,
				row = math.floor((vim.o.lines - h) / 2),
				col = math.floor((vim.o.columns - w) / 2),
			})
		end,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = popup_group,
		pattern = tostring(win),
		once = true,
		callback = function()
			pcall(vim.api.nvim_del_augroup_by_id, popup_group)
		end,
	})

	return buf, win
end

function M.show_help()
	local lines = {
		"  Pack Keymaps",
		"  ============",
		"",
		string.format("  %-10s %-18s %s", "KEY", "SCOPE", "DESCRIPTION"),
		string.format("  %-10s %-18s %s", "---", "-----", "-----------"),
	}
	for _, entry in ipairs(KEYMAP_HELP) do
		table.insert(lines, string.format("  %-10s %-18s %s", entry.key, entry.scope, entry.desc))
	end
	open_popup(lines, { close_keys = { "q", "g?", "<Esc>" }, width_pct = 0.75 })
end

local function plugin_at_cursor(win)
	win = win or 0
	if win ~= 0 and not vim.api.nvim_win_is_valid(win) then
		return nil
	end
	local cursor = vim.api.nvim_win_get_cursor(win)
	return plugin_map[cursor[1]]
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

	-- Advance cursor down to next line for fast fluid multi-selection
	if win_id and vim.api.nvim_win_is_valid(win_id) then
		local cursor = vim.api.nvim_win_get_cursor(win_id)
		local line_count = vim.api.nvim_buf_line_count(buf_id)
		if cursor[1] < line_count then
			pcall(vim.api.nvim_win_set_cursor, win_id, { cursor[1] + 1, cursor[2] })
		end
	end
end

function M.clear_select()
	selected_plugins = {}
	M.update()
end

function M.clean()
	local init = require("pack")
	local ok_get, managed = pcall(function()
		return init.native_pack.get and init.native_pack.get() or {}
	end)
	if not ok_get then
		managed = {}
	end
	local configured = state.get_plugins()
	local removed = 0
	for _, entry in ipairs(managed) do
		local name = entry.spec and entry.spec.name
		if name and not (configured[name] and configured[name].managed) then
			pcall(function()
				vim.pack.del({ name })
			end)
			removed = removed + 1
		end
	end
	if removed > 0 then
		vim.notify("pack: Removed " .. removed .. " unused plugin(s)", vim.log.levels.INFO)
	else
		vim.notify("pack: Already clean", vim.log.levels.INFO)
	end
	M.update()
end

function M.uninstall()
	local targets = {}
	for name, _ in pairs(selected_plugins) do
		table.insert(targets, name)
	end
	if #targets == 0 then
		local p = plugin_at_cursor()
		if p then
			table.insert(targets, p.name)
		end
	end

	if #targets == 0 then
		vim.notify("pack: No plugin selected for uninstallation", vim.log.levels.WARN)
		return
	end

	local msg = #targets == 1 and string.format("Uninstall '%s' from disk? (y/N): ", targets[1])
		or string.format("Uninstall %d selected plugins from disk? (y/N): ", #targets)

	vim.ui.input({ prompt = msg }, function(input)
		if input and input:lower():sub(1, 1) == "y" then
			for _, name in ipairs(targets) do
				local p = state.get_plugins()[name]
				pcall(function()
					vim.pack.del({ name })
				end)
				if p and p.managed == false then
					state.remove_plugin(name)
				else
					state.update_status(name, "missing")
				end
				selected_plugins[name] = nil
			end
			vim.notify(
				string.format("pack: Uninstalled %d plugin(s).", #targets),
				vim.log.levels.INFO
			)
			M.update()
		end
	end)
end

function M.toggle_details()
	local p = plugin_at_cursor()
	if not p then
		return
	end
	expanded_plugins[p.name] = not expanded_plugins[p.name]
	M.update()
end

local function trigger_summary(p)
	local parts = {}
	if p.cmd then
		table.insert(parts, "cmd=" .. vim.inspect(p.cmd))
	end
	if p.event then
		table.insert(parts, "event=" .. vim.inspect(p.event))
	end
	if p.ft then
		table.insert(parts, "ft=" .. vim.inspect(p.ft))
	end
	if p.keys then
		table.insert(parts, "keys=" .. vim.inspect(p.keys))
	end
	if #parts == 0 then
		return "none"
	end
	return table.concat(parts, ", ")
end

local function quick_detail_lines(p)
	local lines = {
		"url:      " .. (p.url or "unknown"),
		"status:   " .. (p.status or "unknown"),
		"managed:  " .. ((p.managed == false) and "no (native — lazy/config not controlled by pack.nvim)" or "yes"),
		"dir:      " .. (p.dir or ""),
		"lazy:     " .. tostring(p.lazy or false),
		"trigger:  " .. trigger_summary(p),
		"disabled: " .. tostring(p.disabled or false),
	}
	if p.category then
		table.insert(lines, "category: " .. p.category)
	end
	if p.tags and #p.tags > 0 then
		table.insert(lines, "tags:     " .. table.concat(p.tags, ", "))
	end
	if p.priority then
		table.insert(lines, "priority: " .. tostring(p.priority))
	end
	if p.load_time then
		table.insert(lines, string.format("load time: %.2f ms", p.load_time))
	end
	if p.dependencies and #p.dependencies > 0 then
		local deps = {}
		for _, d in ipairs(p.dependencies) do
			table.insert(deps, state.derive_name(d) or tostring(d))
		end
		table.insert(lines, "deps:     " .. table.concat(deps, ", "))
	end
	if p.build then
		table.insert(lines, "build:    " .. vim.inspect(p.build))
	end
	return lines
end

function M.show_full_details()
	local p = plugin_at_cursor()
	if not p then
		return
	end

	local lines = { "  " .. p.name, "  " .. string.rep("=", #p.name), "" }
	for _, dl in ipairs(quick_detail_lines(p)) do
		table.insert(lines, "  " .. dl)
	end

	table.insert(lines, "")
	table.insert(lines, "  Git & Working Tree Status")
	table.insert(lines, "  -------------------------")

	local commit_line = "(no commit info available)"
	if p.dir and p.dir ~= "" and vim.fn.isdirectory(p.dir .. "/.git") == 1 then
		local branch = vim.fn.system({ "git", "-C", p.dir, "rev-parse", "--abbrev-ref", "HEAD" })
		if vim.v.shell_error == 0 and branch ~= "" then
			table.insert(lines, "  branch:   " .. vim.trim(branch))
		end

		local result = vim.fn.system({ "git", "-C", p.dir, "log", "-1", "--format=%h %s (%cr) <%an>" })
		if vim.v.shell_error == 0 and result ~= "" then
			commit_line = vim.trim(result)
		end

		local status_out = vim.fn.system({ "git", "-C", p.dir, "status", "--porcelain" })
		if vim.v.shell_error == 0 and vim.trim(status_out) ~= "" then
			table.insert(lines, "  working:  has uncommitted local changes")
		else
			table.insert(lines, "  working:  clean")
		end
	end
	table.insert(lines, "  commit:   " .. commit_line)

	if p.behind ~= nil then
		table.insert(lines, "  behind:   " .. tostring(p.behind) .. " commit(s)")
	else
		table.insert(lines, "  behind:   not checked")
	end

	if p.outdated_error then
		table.insert(lines, "  check:    " .. tostring(p.outdated_error))
	end

	if p.pending_commits and #p.pending_commits > 0 then
		table.insert(lines, "")
		table.insert(lines, "  Pending Commits (Upstream):")
		for _, commit in ipairs(p.pending_commits) do
			table.insert(lines, "    • " .. commit)
		end
	end

	open_popup(lines, { height_pct = 0.65, width_pct = 0.7 })
end

function M.toggle_disabled()
	-- Only meaningful on the All/Disabled tabs; the Outdated tab has no disable UX.
	if current_tab == "outdated" then
		return
	end
	local targets = {}
	for name, _ in pairs(selected_plugins) do
		local p = state.get_plugins()[name]
		if p then
			table.insert(targets, p)
		end
	end
	if #targets == 0 then
		local p = plugin_at_cursor()
		if p then
			table.insert(targets, p)
		end
	end

	for _, p in ipairs(targets) do
		if p.managed == false then
			vim.notify(
				"pack: '" .. p.name .. "' is native/adopted — pack.nvim does not control its loading",
				vim.log.levels.WARN
			)
		else
			local new_disabled = not p.disabled
			state.set_disabled(p.name, new_disabled)

			if new_disabled then
				if p.status == "loaded" then
					vim.notify(
						"pack: '" .. p.name .. "' disabled but already loaded - restart Neovim to fully unload it",
						vim.log.levels.WARN
					)
				else
					require("pack.loader").remove_triggers(p)
				end
			else
				require("pack.loader").enable(p)
			end
		end
	end
	selected_plugins = {}
	M.update()
end

function M.update_one()
	local targets = {}
	for name, _ in pairs(selected_plugins) do
		table.insert(targets, name)
	end

	if #targets > 0 then
		selected_plugins = {}
		require("pack.async").update_plugins(targets)
		return
	end

	if current_tab ~= "outdated" then
		return
	end
	local p = plugin_at_cursor()
	if p then
		require("pack.async").update_plugin(p)
	end
end

function M.update_all_outdated()
	if current_tab ~= "outdated" then
		return
	end
	local names = {}
	for _, p in pairs(state.get_plugins()) do
		if not p.disabled and p.behind and p.behind > 0 then
			table.insert(names, p.name)
		end
	end
	require("pack.async").update_plugins(names)
end

function M.open(config)
	config_ref = config
	search_term = ""
	selected_plugins = {}
	-- Refresh status/path/rev from native vim.pack before rendering.
	pcall(function()
		state.reconcile_from_native(require("pack").native_pack)
	end)
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
		title = " Pack.nvim ",
		title_pos = "center",
		style = "minimal",
	})

	if vim.v.vim_did_enter == 0 then
		vim.api.nvim_create_autocmd("VimEnter", {
			group = vim.api.nvim_create_augroup("pack_ui_startup_focus", { clear = true }),
			once = true,
			callback = function()
				if win_id and vim.api.nvim_win_is_valid(win_id) then
					vim.api.nvim_set_current_win(win_id)
				end
			end,
		})
	else
		vim.schedule(function()
			if win_id and vim.api.nvim_win_is_valid(win_id) then
				vim.api.nvim_set_current_win(win_id)
			end
		end)
	end

	vim.api.nvim_create_autocmd("VimResized", {
		group = vim.api.nvim_create_augroup("pack_ui_resize", { clear = true }),
		callback = function()
			if not win_id or not vim.api.nvim_win_is_valid(win_id) then
				return true
			end
			local w = math.floor(vim.o.columns * 0.8)
			local h = math.floor(vim.o.lines * 0.8)
			vim.api.nvim_win_set_config(win_id, {
				relative = "editor",
				width = w,
				height = h,
				row = math.floor((vim.o.lines - h) / 2),
				col = math.floor((vim.o.columns - w) / 2),
				title = " Pack.nvim ",
				title_pos = "center",
			})
			M.update()
		end,
	})

	local opts = { buffer = buf_id, noremap = true, silent = true, nowait = true }
	vim.keymap.set("n", "q", "<Cmd>close<CR>", opts)
	vim.keymap.set("n", "g?", "<Cmd>lua require('pack.ui').show_help()<CR>", opts)
	vim.keymap.set("n", "S", "<Cmd>Pack sync<CR>", opts)
	vim.keymap.set("n", "C", "<Cmd>lua require('pack.ui').clean()<CR>", opts)
	vim.keymap.set("n", "X", "<Cmd>lua require('pack.ui').uninstall()<CR>", opts)
	vim.keymap.set("n", "<Space>", "<Cmd>lua require('pack.ui').toggle_select()<CR>", opts)
	vim.keymap.set("n", "v", "<Cmd>lua require('pack.ui').clear_select()<CR>", opts)
	vim.keymap.set("n", "<CR>", "<Cmd>lua require('pack.ui').toggle_details()<CR>", opts)
	vim.keymap.set("n", "K", "<Cmd>lua require('pack.ui').show_full_details()<CR>", opts)
	vim.keymap.set("n", "l", "<Cmd>lua require('pack.ui').show_log()<CR>", opts)
	vim.keymap.set("n", "p", "<Cmd>lua require('pack.ui').show_profile()<CR>", opts)
	vim.keymap.set("n", "d", "<Cmd>lua require('pack.async').show_diff()<CR>", opts)
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

function M.show_profile()
	local profiles = {}
	local total = 0
	for _, p in pairs(state.get_plugins()) do
		if p.load_time then
			table.insert(profiles, p)
			total = total + p.load_time
		end
	end
	table.sort(profiles, function(a, b)
		return a.load_time > b.load_time
	end)

	local lines = { "  Pack Startup Profile", "  ====================", "" }
	local bar_max = 16
	for _, p in ipairs(profiles) do
		local pct = total > 0 and (p.load_time / total) * 100 or 0
		local filled = total > 0 and math.max(1, math.floor((p.load_time / total) * bar_max)) or 0
		local bar = "[" .. string.rep("█", filled) .. string.rep("░", bar_max - filled) .. "]"
		table.insert(
			lines,
			string.format("  %s %3d%%  (%6.2f ms)  %s", bar, math.floor(pct + 0.5), p.load_time, p.name)
		)
	end
	if #profiles == 0 then
		table.insert(lines, "  No profiles recorded.")
	else
		table.insert(lines, "")
		table.insert(lines, string.format("  Total: %8.2f ms  (%d loaded plugins)", total, #profiles))
	end

	local buf = open_popup(lines, { close_keys = { "q", "p", "<Esc>" }, width_pct = 0.7 })
	vim.bo[buf].filetype = "pack_profile"
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
		-- Breathing room below an expanded plugin's info block.
		table.insert(lines, "")
		plugin_map[#lines] = p
	end
end

local function matches_search(p, term)
	if not term or term == "" then
		return true
	end
	local query = term:lower()

	local cat_query = query:match("^cat%s*:%s*(.*)") or query:match("^category%s*:%s*(.*)")
	if cat_query then
		return p.category and p.category:lower():find(cat_query, 1, true) ~= nil
	end

	local tag_query = query:match("^tag%s*:%s*(.*)") or query:match("^tags%s*:%s*(.*)")
	if tag_query then
		if not p.tags then
			return false
		end
		for _, t in ipairs(p.tags) do
			if t:lower():find(tag_query, 1, true) then
				return true
			end
		end
		return false
	end

	if p.name:lower():find(query, 1, true) then
		return true
	end
	if p.category and p.category:lower():find(query, 1, true) then
		return true
	end
	if p.tags then
		for _, t in ipairs(p.tags) do
			if t:lower():find(query, 1, true) then
				return true
			end
		end
	end
	return false
end

local function render_all_tab(lines, highlights)
	local plugins = state.get_plugins()
	local groups =
		{ loaded = {}, installed = {}, missing = {}, installing = {}, updating = {}, building = {}, error = {} }

	for _, p in pairs(plugins) do
		if not p.disabled then
			if matches_search(p, search_term) then
				if groups[p.status] then
					table.insert(groups[p.status], p)
				else
					table.insert(groups.installed, p)
				end
			end
		end
	end

	for _, list in pairs(groups) do
		table.sort(list, function(a, b)
			return a.name < b.name
		end)
	end

	local function render_group(name, list, icon, hl_group)
		if #list > 0 then
			local total_time_str = ""
			if name == "Loaded" then
				local total_time = 0
				for _, p in ipairs(list) do
					if p.load_time then
						total_time = total_time + p.load_time
					end
				end
				if total_time > 0 then
					if total_time < 1 then
						total_time_str = string.format(" (%.2fms)", total_time)
					else
						total_time_str = string.format(" (%.1fms)", total_time)
					end
				end
			end
			table.insert(lines, string.format("  %s (%d)%s", name, #list, total_time_str))
			table.insert(highlights, { line = #lines - 1, col_start = 2, col_end = -1, hl = "Title" })
			for _, p in ipairs(list) do
				local is_selected = selected_plugins[p.name] == true
				local sel_prefix = is_selected and "[✓] " or "[ ] "
				local expand_icon = expanded_plugins[p.name] and "▼" or "▶"
				local time_str = ""
				if p.load_time then
					if p.load_time < 1 then
						time_str = string.format(" (%.2fms)", p.load_time)
					else
						time_str = string.format(" (%.1fms)", p.load_time)
					end
				end
				local tag = (p.managed == false) and "  (native)" or ""
				local line = string.format("    %s%s %s %s%s%s", sel_prefix, expand_icon, icon, p.name, time_str, tag)
				table.insert(lines, line)
				plugin_map[#lines] = p

				local col_offset = 4
				table.insert(highlights, {
					line = #lines - 1,
					col_start = col_offset,
					col_end = col_offset + #sel_prefix,
					hl = is_selected and "DiagnosticOk" or "Comment",
				})
				col_offset = col_offset + #sel_prefix

				table.insert(highlights, {
					line = #lines - 1,
					col_start = col_offset,
					col_end = col_offset + #expand_icon + 1,
					hl = "Comment",
				})
				local icon_start = col_offset + #expand_icon + 1
				local icon_end = icon_start + #icon
				table.insert(
					highlights,
					{ line = #lines - 1, col_start = icon_start, col_end = icon_end, hl = hl_group }
				)

				local name_end = icon_end + 1 + #p.name
				if time_str ~= "" then
					table.insert(
						highlights,
						{ line = #lines - 1, col_start = name_end, col_end = name_end + #time_str, hl = "Comment" }
					)
				end
				if p.managed == false then
					local tag_start = name_end + #time_str
					table.insert(
						highlights,
						{ line = #lines - 1, col_start = tag_start, col_end = tag_start + #tag, hl = "Comment" }
					)
				end

				add_plugin_details(p, lines, highlights, "      ")
			end
			table.insert(lines, "")
		end
	end

	render_group("Not Installed", groups.missing, config_ref.ui.icons.not_loaded, "DiagnosticWarn")
	render_group("Installing", groups.installing, config_ref.ui.icons.sync, "DiagnosticWarn")
	render_group("Updating", groups.updating, config_ref.ui.icons.sync, "DiagnosticWarn")
	render_group("Building", groups.building, config_ref.ui.icons.sync, "DiagnosticWarn")
	render_group("Loaded", groups.loaded, config_ref.ui.icons.loaded, "DiagnosticOk")
	render_group("Installed (Not Loaded)", groups.installed, config_ref.ui.icons.loaded, "DiagnosticInfo")
	render_group("Errors", groups.error, config_ref.ui.icons.error, "DiagnosticError")
end

local function render_outdated_tab(lines, highlights)
	local outdated = {}
	for _, p in pairs(state.get_plugins()) do
		if not p.disabled then
			if (p.behind and p.behind > 0) or p.status == "updating" or p.status == "building" then
				if matches_search(p, search_term) then
					table.insert(outdated, p)
				end
			end
		end
	end
	table.sort(outdated, function(a, b)
		return a.name < b.name
	end)

	if #outdated == 0 then
		table.insert(lines, "  No outdated plugins (press c to check)")
		return
	end

	table.insert(lines, "  Outdated (" .. #outdated .. ")")
	table.insert(highlights, { line = #lines - 1, col_start = 2, col_end = -1, hl = "Title" })

	for _, p in ipairs(outdated) do
		local is_selected = selected_plugins[p.name] == true
		local sel_prefix = is_selected and "[✓] " or "[ ] "
		local expand_icon = expanded_plugins[p.name] and "▼" or "▶"
		local suffix = (p.status == "updating") and "updating…"
			or (p.status == "building") and "building…"
			or ((p.behind or 0) .. " behind")
		table.insert(
			lines,
			string.format("    %s%s %s %s — %s", sel_prefix, expand_icon, config_ref.ui.icons.sync, p.name, suffix)
		)
		plugin_map[#lines] = p

		local col_offset = 4
		table.insert(highlights, {
			line = #lines - 1,
			col_start = col_offset,
			col_end = col_offset + #sel_prefix,
			hl = is_selected and "DiagnosticOk" or "Comment",
		})
		col_offset = col_offset + #sel_prefix

		table.insert(
			highlights,
			{ line = #lines - 1, col_start = col_offset, col_end = col_offset + #expand_icon + 1, hl = "Comment" }
		)
		local icon_start = col_offset + #expand_icon + 1
		table.insert(highlights, {
			line = #lines - 1,
			col_start = icon_start,
			col_end = icon_start + #config_ref.ui.icons.sync,
			hl = "DiagnosticWarn",
		})

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
			-- Breathing room below an expanded plugin's info block.
			table.insert(lines, "")
			plugin_map[#lines] = p
		end
	end
end

local function render_disabled_tab(lines, highlights)
	local disabled = {}
	for _, p in pairs(state.get_plugins()) do
		if p.disabled then
			if matches_search(p, search_term) then
				table.insert(disabled, p)
			end
		end
	end
	table.sort(disabled, function(a, b)
		return a.name < b.name
	end)

	if #disabled == 0 then
		table.insert(lines, "  No disabled plugins")
		return
	end

	table.insert(lines, "  Disabled (" .. #disabled .. ")")
	table.insert(highlights, { line = #lines - 1, col_start = 2, col_end = -1, hl = "Title" })
	for _, p in ipairs(disabled) do
		local is_selected = selected_plugins[p.name] == true
		local sel_prefix = is_selected and "[✓] " or "[ ] "
		local expand_icon = expanded_plugins[p.name] and "▼" or "▶"
		local tag = (p.managed == false) and "  (native)" or ""
		local line = string.format("    %s%s %s%s (%s)", sel_prefix, expand_icon, p.name, tag, p.status)
		table.insert(lines, line)
		plugin_map[#lines] = p

		local col_offset = 4
		table.insert(highlights, {
			line = #lines - 1,
			col_start = col_offset,
			col_end = col_offset + #sel_prefix,
			hl = is_selected and "DiagnosticOk" or "Comment",
		})
		col_offset = col_offset + #sel_prefix

		table.insert(
			highlights,
			{ line = #lines - 1, col_start = col_offset, col_end = col_offset + #expand_icon + 1, hl = "Comment" }
		)
		if p.managed == false then
			local tag_start = col_offset + #expand_icon + 1 + #p.name
			table.insert(
				highlights,
				{ line = #lines - 1, col_start = tag_start, col_end = tag_start + #tag, hl = "Comment" }
			)
		end
		add_plugin_details(p, lines, highlights, "      ")
	end
end

function M.update()
	if not buf_id or not vim.api.nvim_buf_is_valid(buf_id) then
		return
	end

	-- Read the cursor from the dashboard window, not the currently-focused one:
	-- M.update often fires from async callbacks while the user is in another
	-- window, and plugin_at_cursor(0) would resolve against an unrelated cursor.
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

	-- Header
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

	-- Busy line: one shared spinner for whatever async work is running.
	if work_in_progress() then
		local updating = false
		for _, p in pairs(state.get_plugins()) do
			if p.status == "updating" then
				updating = true
				break
			end
		end
		local status_str = SPINNER_FRAMES[spinner_idx]
			.. " "
			.. (updating and "updating…" or "checking for updates…")
		local status_pad = math.max(0, math.floor((win_width - vim.fn.strdisplaywidth(status_str)) / 2))
		table.insert(lines, string.rep(" ", status_pad) .. status_str)
		table.insert(highlights, { line = #lines - 1, col_start = status_pad, col_end = -1, hl = "DiagnosticWarn" })
	else
		table.insert(lines, "")
	end

	-- Render Tab Bar
	local tab_line = "  "
	for i, tab in ipairs(TAB_ORDER) do
		local is_active = (tab == current_tab)
		local label = TAB_LABELS[tab] or (tab:sub(1, 1):upper() .. tab:sub(2))
		local tab_text = string.format(" %d %s ", i, label)

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

		-- If cursor is on a non-plugin line (header/tab bar), jump to first plugin line
		if not plugin_map[cursor[1]] then
			for i = 1, #lines do
				if plugin_map[i] then
					cursor[1] = i
					break
				end
			end
		end

		if cursor[1] > #lines then
			cursor[1] = #lines
		end
		if cursor[1] < 1 then
			cursor[1] = 1
		end
		pcall(vim.api.nvim_win_set_cursor, win_id, cursor)
	end
end

return M
