local state = require("pack.state")

local M = {}

M.KEYMAP_HELP = {
	{ key = "?", desc = "show this help popup" },
	{ key = "q", desc = "close dashboard or popup" },
	{ key = "Tab / S-Tab", desc = "cycle tabs (Plugins -> Updates -> Disabled)" },
	{ key = "v", desc = "toggle selection UI / clear selection if items selected" },
	{ key = "Space", desc = "toggle item selection" },
	{ key = "S", desc = "sync all plugins (install missing, pull updates)" },
	{ key = "s", desc = "sync plugin under cursor" },
	{ key = "c", desc = "check for outdated plugins" },
	{ key = "U", desc = "update all outdated plugins" },
	{ key = "u", desc = "update plugin under cursor" },
	{ key = "d", desc = "delete plugin under cursor from disk" },
	{ key = "D", desc = "delete all disabled plugins from disk" },
	{ key = "x", desc = "toggle disable/enable plugin under cursor" },
	{ key = "<CR>", desc = "toggle inline details (on Updates tab: info & commits)" },
	{ key = "K", desc = "full details in popup (tailored per tab)" },
	{ key = "p", desc = "show startup profile" },
	{ key = "f", desc = "filter plugins (name, cat:category, tag:tag)" },
	{ key = "/", desc = "search buffer (standard Neovim search)" },
}

function M.inspect_oneline(value)
	if type(value) == "table" then
		local items = {}
		for _, v in ipairs(value) do
			table.insert(items, tostring(v))
		end
		return "{" .. table.concat(items, ", ") .. "}"
	end
	return tostring(value)
end

function M.trigger_summary(p)
	local parts = {}
	if p.cmd then
		table.insert(parts, "cmd:" .. M.inspect_oneline(p.cmd))
	end
	if p.event then
		table.insert(parts, "event:" .. M.inspect_oneline(p.event))
	end
	if p.ft then
		table.insert(parts, "ft:" .. M.inspect_oneline(p.ft))
	end
	if p.keys then
		table.insert(parts, "keys:" .. M.inspect_oneline(p.keys))
	end
	return #parts > 0 and table.concat(parts, " ") or nil
end

function M.metadata_lines(p)
	local lines = {}
	table.insert(lines, "dir:      " .. (p.dir ~= "" and p.dir or "(not installed)"))
	table.insert(lines, "url:      " .. p.url)

	local pin = p.commit or p.tag or p.branch or p.version or p.sem_version
	if pin then
		table.insert(lines, "pin:      " .. tostring(pin))
	end
	if p.rev then
		table.insert(lines, "rev:      " .. p.rev:sub(1, 7))
	end

	local triggers = M.trigger_summary(p)
	if triggers then
		table.insert(lines, "triggers: " .. triggers)
	end
	if p.dependencies and #p.dependencies > 0 then
		local dep_names = {}
		for _, dep in ipairs(p.dependencies) do
			if type(dep) == "string" then
				table.insert(dep_names, dep)
			elseif type(dep) == "table" then
				local name = dep.name or dep[1] or dep.src
				table.insert(dep_names, type(name) == "string" and name or tostring(name))
			else
				table.insert(dep_names, tostring(dep))
			end
		end
		if #dep_names > 0 then
			table.insert(lines, "deps:     " .. table.concat(dep_names, ", "))
		end
	end

	if p.category then
		table.insert(lines, "category: " .. tostring(p.category))
	end
	if p.tags and #p.tags > 0 then
		local tag_names = {}
		for _, tag in ipairs(p.tags) do
			table.insert(tag_names, tostring(tag))
		end
		if #tag_names > 0 then
			table.insert(lines, "tags:     " .. table.concat(tag_names, ", "))
		end
	end
	if p.status == "building" and p.build_progress then
		table.insert(lines, string.format("build:    step %d/%d: %s", p.build_progress.current, p.build_progress.total, p.build_progress.desc))
	end

	return lines
end

function M.quick_detail_lines(p)
	local is_busy = p and (p.status == "building" or p.status == "installing" or p.status == "updating" or p.checking == true)
	if is_busy and p.log and #p.log > 0 then
		local lines = { "log:" }
		local start_idx = math.max(1, #p.log - 7)
		for i = start_idx, #p.log do
			table.insert(lines, "  " .. tostring(p.log[i]))
		end
		return lines
	end

	return M.metadata_lines(p)
end

function M.add_plugin_details(p, lines, highlights, indent, expanded_plugins, plugin_map)
	if expanded_plugins[p.name] then
		local detail_lines = M.quick_detail_lines(p)
		for _, dline in ipairs(detail_lines) do
			table.insert(lines, indent .. dline)
			plugin_map[#lines] = p
			table.insert(highlights, { line = #lines - 1, col_start = #indent, col_end = -1, hl = "Comment" })
		end
		table.insert(lines, "")
		plugin_map[#lines] = p
	end
end

function M.matches_search(p, term)
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

function M.render_all_tab(
	lines,
	highlights,
	search_term,
	config_ref,
	expanded_plugins,
	selected_plugins,
	plugin_map,
	show_select_ui
)
	local plugins = state.get_plugins()
	local groups = {
		loaded = {},
		installed = {},
		missing = {},
		queued = {},
		installing = {},
		updating = {},
		building = {},
		error = {},
	}

	for _, p in pairs(plugins) do
		if not p.disabled then
			if M.matches_search(p, search_term) then
				-- "queued" (install) and "queued_update" share one dashboard group;
				-- they're only kept apart so the Updates tab/count can ignore
				-- newly-queued installs.
				local group_key = (p.status == "queued_update") and "queued" or p.status
				if groups[group_key] then
					table.insert(groups[group_key], p)
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

	local has_selections = next(selected_plugins) ~= nil

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
				local render_checkbox = show_select_ui or has_selections or is_selected
				local sel_prefix = render_checkbox and (is_selected and "[✓] " or "[ ] ") or ""
				local expand_icon = expanded_plugins[p.name] and "▼" or "▶"
				local time_str = ""
				if p.load_time then
					if p.load_time < 1 then
						time_str = string.format(" (%.2fms)", p.load_time)
					else
						time_str = string.format(" (%.1fms)", p.load_time)
					end
				end
				local outdated_sign = ""
				if p.behind and p.behind > 0 then
					outdated_sign = string.format("  ↺ %d commit%s behind", p.behind, p.behind > 1 and "s" or "")
				end
				local build_status = ""
				if p.status == "building" then
					if p.build_progress then
						build_status = string.format("  [%d/%d: %s]", p.build_progress.current, p.build_progress.total, p.build_progress.desc)
					elseif p.last_build_line then
						build_status = string.format("  (%s)", p.last_build_line)
					end
				end
				local tag = (p.managed == false) and "  (native)" or ""
				local line = string.format(
					"    %s%s %s %s%s%s%s%s",
					sel_prefix,
					expand_icon,
					icon,
					p.name,
					time_str,
					outdated_sign,
					build_status,
					tag
				)
				table.insert(lines, line)
				plugin_map[#lines] = p

				local col_offset = 4
				if render_checkbox then
					table.insert(highlights, {
						line = #lines - 1,
						col_start = col_offset,
						col_end = col_offset + #sel_prefix,
						hl = is_selected and "DiagnosticOk" or "Comment",
					})
					col_offset = col_offset + #sel_prefix
				end

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
				local curr_pos = name_end + #time_str
				if outdated_sign ~= "" then
					table.insert(
						highlights,
						{
							line = #lines - 1,
							col_start = curr_pos,
							col_end = curr_pos + #outdated_sign,
							hl = "DiagnosticWarn",
						}
					)
					curr_pos = curr_pos + #outdated_sign
				end
				if p.managed == false then
					table.insert(
						highlights,
						{ line = #lines - 1, col_start = curr_pos, col_end = curr_pos + #tag, hl = "Comment" }
					)
				end

				M.add_plugin_details(p, lines, highlights, "      ", expanded_plugins, plugin_map)
			end
			table.insert(lines, "")
		end
	end

	render_group("Not Installed", groups.missing, config_ref.ui.icons.not_loaded, "DiagnosticWarn")
	render_group("Queued", groups.queued, config_ref.ui.icons.queued, "Comment")
	render_group("Installing", groups.installing, config_ref.ui.icons.sync, "DiagnosticWarn")
	render_group("Updating", groups.updating, config_ref.ui.icons.sync, "DiagnosticWarn")
	render_group("Building", groups.building, config_ref.ui.icons.sync, "DiagnosticWarn")
	render_group("Loaded", groups.loaded, config_ref.ui.icons.loaded, "DiagnosticOk")
	render_group("Installed (Not Loaded)", groups.installed, config_ref.ui.icons.loaded, "DiagnosticInfo")
	render_group("Errors", groups.error, config_ref.ui.icons.error, "DiagnosticError")
end

local tabs_mod = require("pack.ui.render.tabs")

function M.render_outdated_tab(
	lines,
	highlights,
	search_term,
	config_ref,
	expanded_plugins,
	selected_plugins,
	plugin_map,
	show_select_ui
)
	return tabs_mod.render_outdated_tab(
		lines,
		highlights,
		search_term,
		config_ref,
		expanded_plugins,
		selected_plugins,
		plugin_map,
		M.matches_search,
		show_select_ui
	)
end

function M.render_disabled_tab(
	lines,
	highlights,
	search_term,
	config_ref,
	expanded_plugins,
	selected_plugins,
	plugin_map,
	show_select_ui
)
	return tabs_mod.render_disabled_tab(
		lines,
		highlights,
		search_term,
		config_ref,
		expanded_plugins,
		selected_plugins,
		plugin_map,
		M.matches_search,
		M.add_plugin_details,
		show_select_ui
	)
end

return M
