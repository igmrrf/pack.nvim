local state = require("pack.state")

local M = {}

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local spinner_idx = 1
local spinner_timer = nil

function M.work_in_progress()
	if package.loaded["pack.async"] and require("pack.async").is_busy() then
		return true
	end
	for _, p in pairs(state.get_plugins()) do
		if
			p.status == "updating"
			or p.status == "installing"
			or p.status == "building"
			or p.status == "queued"
			or p.status == "queued_update"
		then
			return true
		end
	end
	return false
end

function M.stop_spinner()
	if spinner_timer then
		pcall(vim.fn.timer_stop, spinner_timer)
		spinner_timer = nil
	end
end

function M.ensure_spinner(buf_id, update_ui_cb)
	if spinner_timer then
		return
	end
	if not (buf_id and vim.api.nvim_buf_is_valid(buf_id)) then
		return
	end
	spinner_timer = vim.fn.timer_start(100, function()
		if not (buf_id and vim.api.nvim_buf_is_valid(buf_id)) or not M.work_in_progress() then
			M.stop_spinner()
			update_ui_cb()
			return
		end
		spinner_idx = (spinner_idx % #SPINNER_FRAMES) + 1
		update_ui_cb()
		for _, p in pairs(state.get_plugins()) do
			if p.status == "updating" then
				pcall(vim.cmd, "redraw")
				break
			end
		end
	end, { ["repeat"] = -1 })
end

function M.get_status_line(win_width)
	if not M.work_in_progress() then
		return "", false
	end
	local updating = false
	for _, p in pairs(state.get_plugins()) do
		if p.status == "updating" then
			updating = true
			break
		end
	end
	local status_str = SPINNER_FRAMES[spinner_idx] .. " " .. (updating and "updating…" or "checking for updates…")
	local status_pad = math.max(0, math.floor((win_width - vim.fn.strdisplaywidth(status_str)) / 2))
	return string.rep(" ", status_pad) .. status_str, true, status_pad
end

return M
