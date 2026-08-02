local state = require("pack.state")
local render = require("pack.ui.render")

local M = {}

local log_view = nil

local function plugin_is_busy(p)
	return p
		and (
			p.status == "installing"
			or p.status == "updating"
			or p.status == "building"
			or p.checking == true
		)
end

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
		string.format("  %-10s %s", "KEY", "DESCRIPTION"),
		string.format("  %-10s %s", "---", "-----------"),
	}
	for _, entry in ipairs(render.KEYMAP_HELP) do
		table.insert(lines, string.format("  %-10s %s", entry.key, entry.desc))
	end
	M.open_popup(lines, { close_keys = { "q", "?", "<Esc>" }, width_pct = 0.75 })
end

function M.show_full_details(p, current_tab)
	if not p then
		return
	end

	local lines = { "  " .. p.name, "  " .. string.rep("=", #p.name), "" }
	for _, dl in ipairs(render.metadata_lines(p)) do
		table.insert(lines, "  " .. dl)
	end

	if current_tab == "outdated" then
		table.insert(lines, "")
		table.insert(lines, "  Update & Revision Information")
		table.insert(lines, "  -----------------------------")
		table.insert(lines, "  status:          " .. (p.status or "installed"))
		table.insert(lines, "  behind:          " .. tostring(p.behind or 0) .. " commit(s)")
		table.insert(lines, "  revision before: " .. (p.revision_before or "?"))
		table.insert(lines, "  revision after:  " .. (p.revision_after or "?"))
		if p.upstream_branch then
			table.insert(lines, "  upstream branch: " .. p.upstream_branch)
		end
		if p.outdated_error then
			table.insert(lines, "  check error:     " .. tostring(p.outdated_error))
		end

		if p.pending_commits and #p.pending_commits > 0 then
			table.insert(lines, "")
			table.insert(lines, "  Pending Commits (Upstream):")
			for _, commit in ipairs(p.pending_commits) do
				table.insert(lines, "    • " .. commit)
			end
		end
	elseif current_tab == "disabled" then
		table.insert(lines, "")
		table.insert(lines, "  Disabled State Information")
		table.insert(lines, "  --------------------------")
		table.insert(lines, "  disabled:  true (persisted)")
		table.insert(lines, "  status:    " .. (p.status or "unknown"))
		table.insert(lines, "  managed:   " .. tostring(p.managed ~= false))
		table.insert(lines, "  location:  " .. (p.dir ~= "" and p.dir or "(not on disk)"))
	else
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
	end

	M.open_popup(lines, { height_pct = 0.65, width_pct = 0.7 })
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

	local buf = M.open_popup(lines, { close_keys = { "q", "p", "<Esc>" }, width_pct = 0.7 })
	vim.bo[buf].filetype = "pack_profile"
end

function M.update_log()
	local v = log_view
	if not v then
		return
	end
	if not (vim.api.nvim_buf_is_valid(v.buf) and vim.api.nvim_win_is_valid(v.win)) then
		log_view = nil
		return
	end
	local p = state.get_plugins()[v.name]
	local log = (p and p.log) or {}
	if #log == v.last and log == v.log_ref then
		return
	end

	local at_bottom = true
	local ok, cur = pcall(vim.api.nvim_win_get_cursor, v.win)
	if ok then
		at_bottom = cur[1] >= v.last
	end

	v.last = #log
	v.log_ref = log
	vim.bo[v.buf].modifiable = true
	pcall(vim.api.nvim_buf_set_lines, v.buf, 0, -1, false, log)
	vim.bo[v.buf].modifiable = false
	if at_bottom then
		pcall(vim.api.nvim_win_set_cursor, v.win, { math.max(1, #log), 0 })
	end
end

function M.show_log(p)
	if not p or not p.log or #p.log == 0 then
		vim.notify("No logs available for this item.", vim.log.levels.INFO)
		return
	end
	local buf, win = M.open_popup(p.log, { wrap = true })
	vim.bo[buf].filetype = "pack_log"
	pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, #p.log), 0 })
	log_view = { name = p.name, buf = buf, win = win, last = #p.log, log_ref = p.log }

	if not plugin_is_busy(p) then
		return buf, win
	end
	local timer
	timer = vim.fn.timer_start(120, function()
		if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_win_is_valid(win)) then
			log_view = nil
			pcall(vim.fn.timer_stop, timer)
			return
		end
		M.update_log()
		if not plugin_is_busy(state.get_plugins()[p.name]) then
			M.update_log()
			pcall(vim.fn.timer_stop, timer)
			local target_p = state.get_plugins()[p.name] or p
			if vim.api.nvim_win_is_valid(win) then
				pcall(vim.api.nvim_win_close, win, true)
				M.show_full_details(target_p)
			end
		end
	end, { ["repeat"] = -1 })
	return buf, win
end

return M
