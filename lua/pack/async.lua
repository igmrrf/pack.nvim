local state = require("pack.state")

local M = {}

M.max_log_lines = 500

-- Hard timeout (ms) for a single read-only git probe. Without it a hung fetch
-- (network black-hole, a private repo prompting for credentials with no tty)
-- would never fire its callback, so run_queued's `inflight` never drops, the
-- queue wedges, and the dashboard spinner spins forever. vim.system kills the
-- process on timeout and still invokes on_exit (non-zero code), so the callback
-- chain -> done -> pump keeps flowing.
M.git_timeout = 60000

-- How long (ms) to wait for a PackChanged(update) before force-restoring a
-- plugin's status from "updating" (guards against native emitting no event).
M.update_recover_ms = 30000

local function append_log(plugin, line)
	plugin.log = plugin.log or {}
	table.insert(plugin.log, line)
	if #plugin.log > M.max_log_lines then
		table.remove(plugin.log, 1)
	end
end

local function ui_update()
	if package.loaded["pack.ui"] then
		require("pack.ui").update()
	end
end

local git_mod = require("pack.async.git")
local build_mod = require("pack.async.build")

local function git(plugin, args, cwd, on_done)
	git_mod.git(plugin, args, cwd, M.max_log_lines, M.git_timeout, append_log, on_done)
end

function M.parse_behind_count(output)
	return git_mod.parse_behind_count(output)
end

function M.parse_revision_pair(output)
	return git_mod.parse_revision_pair(output)
end

function M.parse_upstream_branch_name(output)
	return git_mod.parse_upstream_branch_name(output)
end

function M.parse_pending_commits(output)
	return git_mod.parse_pending_commits(output)
end

function M.upstream_ref(plugin, dir, cb)
	return git_mod.upstream_ref(plugin, dir, git, cb)
end

-- Shared in-flight activity counter. Async work brackets itself with
-- begin_activity/end_activity so the dashboard can drive ONE spinner instead of
-- each task animating independently. Every started task must end exactly once.
local activity = 0

local function begin_activity()
	activity = activity + 1
	ui_update()
	if package.loaded["pack.ui"] then
		require("pack.ui").ensure_spinner()
	end
end

local function end_activity()
	if activity > 0 then
		activity = activity - 1
	end
	ui_update()
end

function M.is_busy()
	return activity > 0
end

-- done() is invoked exactly once when the check finishes on any path, so callers
-- can pair it with end_activity for accurate busy tracking.
function M.check_outdated(plugin, done)
	done = done or function() end
	local finished = false
	local function finish()
		if finished then
			return
		end
		finished = true
		plugin.checking = nil
		done()
	end

	if plugin.disabled or (plugin.status ~= "installed" and plugin.status ~= "loaded") then
		return finish()
	end
	local dir = plugin.dir
	if not dir or dir == "" or vim.fn.isdirectory(dir) == 0 then
		return finish()
	end
	-- Re-entrancy guard: a second check (double `c`, or `c` racing the auto-check
	-- on dashboard open) while this one is in flight would spawn a duplicate
	-- `git fetch` in the same worktree (lock contention, interleaved logs). Bail
	-- if one is already running; `checked_at` alone can't cover this because it's
	-- only set at the END of a successful check. Bail via done() directly, not
	-- finish() -- finish() clears `checking`, which belongs to the in-flight run.
	if plugin.checking then
		return done()
	end
	plugin.checking = true

	git(plugin, { "fetch" }, dir, function(fetch_code)
		if fetch_code ~= 0 then
			-- A read-only outdated probe must NEVER mutate load status. A transient
			-- fetch failure (offline, DNS, private-repo auth prompt) would otherwise
			-- flip a not-yet-loaded lazy plugin to "error", and loader.load
			-- early-returns on "error" -- permanently killing that plugin's lazy
			-- triggers for the session. Record the probe error only; "error" stays
			-- reserved for real packadd/load failures.
			state.set_outdated_detail(plugin.name, { error = "Upstream fetch failed" })
			ui_update()
			return finish()
		end

		M.upstream_ref(plugin, dir, function(ref)
			if not ref then
				-- Pinned (tag/commit/version) or no resolvable upstream: not "outdated".
				state.set_behind(plugin.name, 0)
				state.set_outdated_detail(plugin.name, {})
				ui_update()
				return finish()
			end

			git(plugin, { "rev-list", "--count", "HEAD.." .. ref }, dir, function(count_code, count_out)
				if count_code ~= 0 then
					return finish()
				end
				local behind = M.parse_behind_count(count_out)
				if not behind then
					return finish()
				end
				state.set_behind(plugin.name, behind)
				ui_update()

				if behind == 0 then
					state.set_outdated_detail(plugin.name, {})
					return finish()
				end

				-- `--short` only tolerates one rev at a time; resolve full hashes and
				-- truncate ourselves.
				git(plugin, { "rev-parse", "HEAD", ref }, dir, function(rev_code, rev_out)
					local revision_before, revision_after
					if rev_code == 0 then
						local full_before, full_after = M.parse_revision_pair(rev_out)
						revision_before = full_before and full_before:sub(1, 7)
						revision_after = full_after and full_after:sub(1, 7)
					end

					local upstream_branch = ref:gsub("^origin/", "")

					git(plugin, { "log", "--format=%h │ %s", "HEAD.." .. ref }, dir, function(log_code, log_out)
						local pending_commits = {}
						if log_code == 0 then
							pending_commits = M.parse_pending_commits(log_out)
						end
						state.set_outdated_detail(plugin.name, {
							revision_before = revision_before,
							revision_after = revision_after,
							upstream_branch = upstream_branch,
							pending_commits = pending_commits,
						})
						ui_update()
						return finish()
					end)
				end)
			end)
		end) -- close M.upstream_ref callback
	end)
end

local queue_mod = require("pack.async.queue")

M.max_concurrency = queue_mod.max_concurrency
M.outdated_cooldown = queue_mod.outdated_cooldown

function M.run_queued(items, worker, limit)
	return queue_mod.run_queued(items, worker, limit)
end

function M.outdated_targets()
	return queue_mod.outdated_targets()
end

function M.check_all_outdated()
	M.run_queued(M.outdated_targets(), function(p, done)
		begin_activity()
		M.check_outdated(p, function()
			end_activity()
			done()
		end)
	end, M.max_concurrency)
end

function M.run_build_hook(plugin, done_cb)
	return build_mod.run_build_hook(plugin, append_log, done_cb)
end

function M.setup_build_hooks()
	return build_mod.setup_build_hooks(function(p, cb)
		M.run_build_hook(p, cb)
	end, append_log)
end

local diff_mod = require("pack.async.diff")

function M.show_diff()
	return diff_mod.show_diff()
end

-- Update a plugin (or list of plugins) by delegating to native vim.pack.
-- force=true skips native's confirmation buffer -- the dashboard IS the
-- confirmation, so an in-dashboard `u`/`U` updates immediately.
function M.update_plugin(plugin)
	M.update_plugins({ plugin.name })
end

-- Update many plugins in ONE native call. Calling native update once per plugin
-- spawns one blocking progress job apiece ("vim.pack: 100% updating (1/1)"
-- stacking N times); a single batched call shows one aggregated progress.
function M.update_plugins(names)
	if not names or #names == 0 then
		return
	end
	local pack = require("pack")
	if not (pack.native_pack and pack.native_pack.update) then
		return
	end
	-- Native update runs async (its own progress notification), so flip the
	-- targeted plugins to "updating" and repaint first: the dashboard shows the
	-- in-flight state ("updating…" in Outdated, the Updating group in All) instead
	-- of the user staring at a frozen list. PackChanged(update) restores status.
	local plugins = state.get_plugins()
	for _, name in ipairs(names) do
		local p = plugins[name]
		if p then
			p.status_before_update = p.status
			state.update_status(name, "updating")
		end
	end
	ui_update()
	if package.loaded["pack.ui"] then
		require("pack.ui").ensure_spinner()
	end

	-- Restore any of `names` still stuck in "updating" back to its prior status.
	-- Covers both a synchronous throw below and the silent case where native
	-- emits no PackChanged(update) (e.g. a plugin already at its latest revision),
	-- which would otherwise leave the dashboard showing "updating…" forever.
	local function recover()
		for _, name in ipairs(names) do
			local p = plugins[name]
			if p and p.status == "updating" then
				state.update_status(name, p.status_before_update or "installed")
				p.status_before_update = nil
			end
		end
		ui_update()
	end

	local ok, err = pcall(pack.native_pack.update, names, { force = true })
	if not ok then
		vim.notify("pack: update failed: " .. tostring(err), vim.log.levels.ERROR)
		recover()
		return
	end
	-- Fallback timer for the no-event case; PackChanged(update) normally restores
	-- status well before this fires.
	vim.defer_fn(recover, M.update_recover_ms)
end

return M
