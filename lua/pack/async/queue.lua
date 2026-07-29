local state = require("pack.state")

local M = {}

M.max_concurrency = 8
M.outdated_cooldown = 300

function M.run_queued(items, worker, limit)
	limit = limit or M.max_concurrency
	local idx, inflight = 0, 0
	local pumping = false
	local function pump()
		if pumping then
			return
		end
		pumping = true
		while inflight < limit and idx < #items do
			idx = idx + 1
			inflight = inflight + 1
			local item = items[idx]
			local finished = false
			worker(item, function()
				if finished then
					return
				end
				finished = true
				inflight = inflight - 1
				pump()
			end)
		end
		pumping = false
	end
	pump()
end

function M.outdated_targets()
	local now = os.time()
	local targets = {}
	for _, p in pairs(state.get_plugins()) do
		if not p.disabled and (p.status == "installed" or p.status == "loaded") and not p.checking then
			if not (p.checked_at and (now - p.checked_at) < M.outdated_cooldown) then
				targets[#targets + 1] = p
			end
		end
	end
	return targets
end

return M
