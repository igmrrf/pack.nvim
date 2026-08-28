local state = require("pack.state")

local M = {}

M.TAB_ORDER = { "all", "outdated", "disabled" }
M.TAB_LABELS = {
	all = "Plugins",
	outdated = "Updates",
	disabled = "Disabled",
}

M.HELP_ITEMS = {
	all = {
		base = { "[S] Sync All", "[v] Select", "[Tab] Tabs", "[?] Help" },
		optional = { "[s] Sync", "[d] Delete" },
	},
	outdated = {
		base = { "[U] Update All", "[<CR>] Details", "[Tab] Tabs", "[?] Help" },
		optional = { "[c] Check", "[u] Update" },
	},
	disabled = {
		base = { "[D] Delete All Disabled", "[v] Select", "[Tab] Tabs", "[?] Help" },
		optional = { "[d] Delete" },
	},
}

function M.get_tab_counts()
	local plugins = state.get_plugins()
	local counts = { all = 0, outdated = 0, disabled = 0 }
	for _, p in pairs(plugins) do
		if p.disabled then
			counts.disabled = counts.disabled + 1
		else
			counts.all = counts.all + 1
			if
				(p.behind and p.behind > 0)
				or p.status == "queued_update"
				or p.status == "updating"
				or p.status == "building"
			then
				counts.outdated = counts.outdated + 1
			end
		end
	end
	return counts
end

function M.render_tab_bar(lines, highlights, current_tab)
	local counts = M.get_tab_counts()
	local tab_line = "  "

	for _, tab in ipairs(M.TAB_ORDER) do
		local is_active = (tab == current_tab)
		local count = counts[tab] or 0
		local pill_text = ""

		if tab == "all" then
			if is_active then
				pill_text = string.format(" ● Plugins (%d) ", count)
			else
				pill_text = string.format("  Plugins (%d) ", count)
			end
		elseif tab == "outdated" then
			if is_active then
				pill_text = string.format(" ● Updates (%d) ", count)
			else
				pill_text = string.format(" ↺ Updates (%d) ", count)
			end
		elseif tab == "disabled" then
			if is_active then
				pill_text = string.format(" ● Disabled (%d) ", count)
			else
				pill_text = string.format(" 󰂭 Disabled (%d) ", count)
			end
		end

		local start_col = #tab_line
		tab_line = tab_line .. pill_text
		local end_col = #tab_line

		if is_active then
			table.insert(highlights, { line = #lines, col_start = start_col, col_end = end_col, hl = "TabLineSel" })
		else
			table.insert(highlights, { line = #lines, col_start = start_col, col_end = end_col, hl = "TabLine" })
		end
		tab_line = tab_line .. "     "
	end

	table.insert(lines, tab_line)
	table.insert(lines, "")
end

function M.render_quick_help(lines, highlights, current_tab, win_width)
	win_width = win_width or 80
	local tab_spec = M.HELP_ITEMS[current_tab] or M.HELP_ITEMS.all
	local active_items = {}
	for _, item in ipairs(tab_spec.base) do
		table.insert(active_items, item)
	end

	if tab_spec.optional then
		for _, opt_item in ipairs(tab_spec.optional) do
			local test_items = {}
			for _, item in ipairs(active_items) do
				table.insert(test_items, item)
			end
			table.insert(test_items, opt_item)
			local test_str = table.concat(test_items, "  •  ")
			local str_w = (vim.api and vim.api.nvim_strwidth) and vim.api.nvim_strwidth(test_str) or #test_str
			if str_w <= math.max(20, win_width - 4) then
				active_items = test_items
			else
				break
			end
		end
	end

	local help_text = table.concat(active_items, "  •  ")
	local text_w = (vim.api and vim.api.nvim_strwidth) and vim.api.nvim_strwidth(help_text) or #help_text
	local pad = math.max(0, math.floor((win_width - text_w) / 2))
	local centered_text = string.rep(" ", pad) .. help_text
	table.insert(lines, centered_text)
	table.insert(highlights, {
		line = #lines - 1,
		col_start = pad,
		col_end = pad + #help_text,
		hl = "Comment",
	})
end

return M
