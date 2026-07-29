local state = require("pack.state")

local M = {}

function M.render_outdated_tab(lines, highlights, search_term, config_ref, expanded_plugins, selected_plugins, plugin_map, matches_search_fn)
	local outdated = {}
	for _, p in pairs(state.get_plugins()) do
		if not p.disabled then
			if (p.behind and p.behind > 0) or p.status == "updating" or p.status == "building" then
				if matches_search_fn(p, search_term) then
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
			table.insert(lines, "")
			plugin_map[#lines] = p
		end
	end
end

function M.render_disabled_tab(lines, highlights, search_term, config_ref, expanded_plugins, selected_plugins, plugin_map, matches_search_fn, add_details_fn)
	local disabled = {}
	for _, p in pairs(state.get_plugins()) do
		if p.disabled then
			if matches_search_fn(p, search_term) then
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
		add_details_fn(p, lines, highlights, "      ", expanded_plugins, plugin_map)
	end
end

return M
