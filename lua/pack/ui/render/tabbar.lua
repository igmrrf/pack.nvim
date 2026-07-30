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

M.HEADER_HELP = {
	all = "  S sync  •  C clean  •  Space select  •  Enter details  •  K info  •  l log  •  / filter  •  ? help  •  q close",
	outdated = "  c check  •  u update  •  U update all  •  d diff  •  Enter details  •  / filter  •  ? help  •  q close",
	disabled = "  x enable  •  Space select  •  v clear select  •  Enter details  •  / filter  •  ? help  •  q close",
}
M.FOOTER_HELP = M.HEADER_HELP

function M.render_quick_help(lines, highlights, current_tab)
	local help_text = M.HEADER_HELP[current_tab] or M.HEADER_HELP.all
	table.insert(lines, help_text)
	table.insert(highlights, { line = #lines - 1, col_start = 0, col_end = -1, hl = "Comment" })
end

return M
