local M = {}

M.TAB_ORDER = { "all", "outdated", "disabled" }
M.TAB_LABELS = {
	all = "Plugins",
	outdated = "Updates",
	disabled = "Disabled",
}

function M.render_tab_bar(lines, highlights, current_tab)
	local tab_line = "  "
	for i, tab in ipairs(M.TAB_ORDER) do
		local is_active = (tab == current_tab)
		local label = M.TAB_LABELS[tab] or (tab:sub(1, 1):upper() .. tab:sub(2))
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
end

return M
