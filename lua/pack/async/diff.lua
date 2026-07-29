local state = require("pack.state")
local popup = require("pack.ui.popup")

local M = {}

function M.show_diff()
	local outdated = {}
	for _, p in pairs(state.get_plugins()) do
		if not p.disabled and p.behind and p.behind > 0 then
			table.insert(outdated, p)
		end
	end
	table.sort(outdated, function(a, b)
		return a.name < b.name
	end)

	if #outdated == 0 then
		vim.notify("pack: No pending updates for diff", vim.log.levels.INFO)
		return
	end

	local lines = {
		"  Pack Pending Updates Diff",
		"  =========================",
		"",
	}

	for _, p in ipairs(outdated) do
		local branch_suffix = p.upstream_branch and (" (" .. p.upstream_branch .. ")") or ""
		table.insert(lines, string.format("  • %s  (%d behind)%s", p.name, p.behind or 0, branch_suffix))
		table.insert(
			lines,
			string.format("    rev: %s -> %s", p.revision_before or "?", p.revision_after or "?")
		)
		if p.pending_commits and #p.pending_commits > 0 then
			for _, commit in ipairs(p.pending_commits) do
				table.insert(lines, "    │ " .. commit)
			end
		end
		table.insert(lines, "")
	end

	local buf = popup.open_popup(lines, { close_keys = { "q", "d", "<Esc>" }, width_pct = 0.75 })
	vim.bo[buf].filetype = "pack_diff"
end

return M
