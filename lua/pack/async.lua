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

local ui_update_timer = nil

local function ui_update()
	if not package.loaded["pack.ui"] then
		return
	end
	if ui_update_timer then
		return
	end
	ui_update_timer = vim.defer_fn(function()
		ui_update_timer = nil
		if package.loaded["pack.ui"] then
			require("pack.ui").update()
		end
	end, 50)
end

local function get_progress_prefix(line)
	if type(line) ~= "string" then
		return nil
	end
	local trimmed = vim.trim(line)
	local prefix = trimmed:match("^(remote:%s*[^:]+:)")
	if prefix then
		return prefix
	end
	if trimmed:match("^Cloning into") then
		return "Cloning into"
	end
	if trimmed:match("^%s*%d+%%") or trimmed:match("^%[%s*%d+%%") then
		return "progress_percent"
	end
	return nil
end

local function append_log(plugin, line)
	if not line or line == "" then
		return
	end
	plugin.log = plugin.log or {}
	local new_prefix = get_progress_prefix(line)
	if new_prefix and #plugin.log > 0 then
		local last_line = plugin.log[#plugin.log]
		local last_prefix = get_progress_prefix(last_line)
		if last_prefix and last_prefix == new_prefix then
			plugin.log[#plugin.log] = line
			ui_update()
			return
		end
	end
	table.insert(plugin.log, line)
	if #plugin.log > M.max_log_lines then
		table.remove(plugin.log, 1)
	end
	ui_update()
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
	if not dir or dir == "" or vim.fn.isdirectory(dir) == 0 or not vim.uv.fs_stat(vim.fs.joinpath(dir, ".git")) then
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

function M.install_missing_plugins(specs, confirm, done_cb)
	done_cb = done_cb or function() end
	if not specs or #specs == 0 then
		return done_cb()
	end

	local pack = require("pack")
	local loader = require("pack.loader")
	local i = 1
	local function install_next()
		if i > #specs then
			done_cb()
			return
		end

		pack._in_pack_op = true
		local ok, err = pcall(
			pack.native_pack.add,
			{ specs[i] },
			{ load = loader.load_fn, confirm = confirm, silent = true }
		)
		pack._in_pack_op = false

		if not ok then
			vim.notify("pack: native vim.pack.add failed: " .. tostring(err), vim.log.levels.WARN)
		end

		i = i + 1
		vim.defer_fn(install_next, 10)
	end
	install_next()
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

-- Maximum number of plugin names handed to native vim.pack.update per call.
-- The `U` (update all outdated), `S` (sync), and `:Pack update` flows funnel
-- every target through update_plugins, so capping here is what keeps each
-- native progress job small instead of one giant transfer for the whole fleet.
M.update_batch_size = 5

-- Split `items` into chunks of AT MOST `max_per_call` items each:
-- 12 -> {5,5,2}, 7 -> {5,2}, 3 -> {3}.
function M.split_update_batches(items, max_per_call)
	max_per_call = math.max(1, max_per_call or M.update_batch_size)
	local batches = {}
	for i = 1, #items, max_per_call do
		local batch = {}
		for j = i, math.min(i + max_per_call - 1, #items) do
			table.insert(batch, items[j])
		end
		table.insert(batches, batch)
	end
	return batches
end

function M.use_git_enabled()
	local pack = require("pack")
	return pack.config and pack.config.use_git == true
end

-- A plugin can be updated with background git only when nothing pins it to a
-- fixed revision and its directory is a real git worktree we can fast-forward.
local function bg_plugin_supported(p)
	if not p or p.disabled or p.is_local or p.managed == false then
		return false
	end
	if p.tag or p.commit or p.version or p.sem_version then
		return false
	end
	local dir = p.dir
	if not dir or dir == "" or vim.fn.isdirectory(dir) == 0 then
		return false
	end
	return vim.uv.fs_stat(vim.fs.joinpath(dir, ".git")) ~= nil
end

-- True when an install spec can be satisfied by a background `git clone`.
-- Branch/tag pins clone via --branch; commit hashes checkout after the clone.
-- Semver RANGES need native's resolution logic, so they are excluded.
function M.bg_install_supported(spec)
	if type(spec) ~= "table" or not spec.src or not spec.name then
		return false
	end
	return spec.version == nil or type(spec.version) == "string"
end

local SHA_PATTERN = "^%x%x%x%x%x%x%x[%x]*$"

-- A ref name passed to `git clone --branch` must never start with "-": git
-- would parse it as an option (argument injection), not a branch/tag.
local function safe_ref_name(value)
	if type(value) ~= "string" or value == "" or value:sub(1, 1) == "-" then
		return nil
	end
	return value
end

-- Concurrent background clones (bounded pump, up to max_concurrency at once)
-- can each finish close together and want to write the lockfile. update_entry()
-- does a blocking read -> `git rev-parse` -> write, and Neovim's synchronous git
-- subprocess call can pump the event loop while it waits -- letting a second
-- clone's completion run its own update_entry() nested inside the first one's
-- wait, read the same not-yet-written file, and clobber it on write. Serialize
-- every write through this queue so only one update_entry() call is ever
-- actually in flight; a write requested while one is running just waits its turn.
local lockfile_write_queue = {}
local lockfile_writing = false

local function process_lockfile_writes()
	if lockfile_writing then
		return
	end
	local job = table.remove(lockfile_write_queue, 1)
	if not job then
		return
	end
	lockfile_writing = true
	pcall(require("pack.lockfile").update_entry, job.name, job.src, job.dir)
	lockfile_writing = false
	process_lockfile_writes()
end

local function queue_lockfile_write(name, src, dir)
	table.insert(lockfile_write_queue, { name = name, src = src, dir = dir })
	process_lockfile_writes()
end

-- Clone `spec` in the BACKGROUND via vim.system so the UI never blocks on a
-- big transfer. On success the caller must still hand the spec to native
-- vim.pack.add: the directory already exists by then, so native just adopts
-- it, registers it, and writes the lockfile entry.
function M.install_via_git(spec, done)
	done = done or function() end
	local dir = vim.fs.joinpath(state.native_opt_dir(), spec.name)
	-- Remember whether the target existed before we started: a failed clone
	-- leaves a HALF-cloned directory behind, which normalize() would treat as
	-- installed on the next startup. Only ever clean up what we created.
	local existed_before = vim.fn.isdirectory(dir) == 1
	local version = type(spec.version) == "string" and safe_ref_name(spec.version) or nil
	local args = { "clone" }
	if version and not version:match(SHA_PATTERN) then
		-- Covers both branches ("main") and tags ("v1.2.0"). Hex-like values are
		-- treated as commits instead (see SHA_PATTERN): clone the default branch,
		-- then check out the revision below.
		table.insert(args, "--branch")
		table.insert(args, version)
	end
	table.insert(args, spec.src)
	table.insert(args, dir)

	local log_target = state.get_plugins()[spec.name] or { name = spec.name }

	-- A failed install must leave NO directory behind: a half-cloned target
	-- would look "installed" to normalize() on the next startup and get adopted
	-- in a broken state. Only ever clean up what we created ourselves.
	local function fail()
		if not existed_before and vim.fn.isdirectory(dir) == 1 then
			pcall(vim.fn.delete, dir, "rf")
		end
		done(false)
	end

	begin_activity()
	git(log_target, args, nil, function(code)
		end_activity()
		if code ~= 0 then
			vim.notify(
				("pack: background git clone failed for %s (exit %d) - see the plugin's log"):format(spec.name, code),
				vim.log.levels.ERROR
			)
			return fail()
		end

		local function success()
			queue_lockfile_write(spec.name, spec.src, dir)
			done(true)
		end

		-- Commit pin: check out the exact revision after a default clone.
		if version and version:match(SHA_PATTERN) then
			begin_activity()
			git(log_target, { "checkout", "--detach", version }, dir, function(co_code)
				end_activity()
				if co_code ~= 0 then
					vim.notify(
						("pack: background git checkout failed for %s - see the plugin's log"):format(spec.name),
						vim.log.levels.ERROR
					)
					return fail()
				end
				success()
			end)
			return
		end
		success()
	end)
end

-- Fast-forward ONE plugin in the background (fetch + ff-only merge), then let
-- the caller reconcile state. Never touches pinned plugins; those fall back.
function M.bg_update_one(p, done)
	done = done or function() end
	local dir = p.dir
	begin_activity()
	git(p, { "fetch" }, dir, function(fetch_code)
		if fetch_code ~= 0 then
			end_activity()
			return done(false)
		end
		M.upstream_ref(p, dir, function(ref)
			if not ref then
				end_activity()
				return done(false)
			end
			git(p, { "merge", "--ff-only", ref }, dir, function(merge_code)
				end_activity()
				done(merge_code == 0)
			end)
		end)
	end)
end

-- Update many plugins in batches of AT MOST update_batch_size names per
-- native call (see split_update_batches). With `use_git = true`, the actual
-- transfer happens as backgrounded git jobs instead, and one final batched
-- native vim.pack.update pass runs afterwards purely to reconcile the
-- lockfile/state once HEAD has already moved -- keeping the UI responsive
-- during large updates.
-- Statuses owned by a DIFFERENT pipeline (install/build) than update_plugins
-- itself. Deliberately excludes "queued_update"/"updating": those are
-- update_plugins' own states, and re-invoking it on a name already mid-update
-- is long-standing, tested behavior (native handles a redundant update call
-- fine) -- only cross-pipeline clobbering needs guarding against here.
local BUSY_STATUSES = {
	queued = true,
	installing = true,
	building = true,
}

function M.update_plugins(names)
	if not names or #names == 0 then
		return
	end
	local pack = require("pack")
	if not (pack.native_pack and pack.native_pack.update) then
		return
	end

	-- Drop anything already mid-install/mid-build: it has no stable "current
	-- status" to capture into status_before_update, and targeting it here would
	-- stomp whatever operation already has it in flight -- e.g. a plugin still
	-- being cloned by the install pump would get clobbered to "queued_update",
	-- and a later failure here could restore that stale captured status onto a
	-- plugin the install already finished.
	do
		local plugins_snapshot = state.get_plugins()
		local filtered = {}
		for _, name in ipairs(names) do
			local p = plugins_snapshot[name]
			if p and not BUSY_STATUSES[p.status] then
				table.insert(filtered, name)
			end
		end
		names = filtered
	end
	if #names == 0 then
		return
	end

	-- Updates run async, so flip the targeted plugins to "queued_update" and
	-- repaint first: the dashboard shows the pending work (folded into the
	-- Queued group in All; counted in Updates) instead of the user staring at
	-- a frozen list. "queued_update" (not the install path's plain "queued")
	-- so the Updates tab/count -- which cares about outdated plugins, not
	-- newly-queued installs -- can tell the two apart. Each plugin flips on to
	-- "updating" only once a worker slot actually starts its transfer (see
	-- mark_updating below); PackChanged(update) restores status afterwards.
	local plugins = state.get_plugins()
	for _, name in ipairs(names) do
		local p = plugins[name]
		if p then
			p.status_before_update = p.status
			-- Remember whether this was a *real* update (had pending commits) vs a
			-- likely no-op (already at latest). Native fires PackChanged for real
			-- updates but stays silent for no-ops, so the two need different recovery.
			p._update_had_pending = (p.behind or 0) > 0
			state.update_status(name, "queued_update")
		end
	end
	ui_update()
	if package.loaded["pack.ui"] then
		require("pack.ui").ensure_spinner()
	end

	-- Flip a batch/single name from "queued_update" to "updating" right as a
	-- worker slot picks it up. Skips names already "updating" (a bg-updated
	-- plugin riding the final native reconciliation pass is still the same update).
	local function mark_updating(subset)
		for _, name in ipairs(subset) do
			local p = plugins[name]
			if p and p.status == "queued_update" then
				state.update_status(name, "updating")
			end
		end
	end

	-- Restore any of `names` still stuck in "updating" back to its prior status.
	-- Two callers:
	--   * synchronous throw / immediate failure (from_timer=false): flip ALL
	--     targets back immediately.
	--   * fallback timer (from_timer=true): only the silent no-op case needs
	--     rescuing. A plugin that had pending commits is a genuine, possibly slow
	--     update; native WILL fire PackChanged(update) for it, so leave it
	--     "updating" and let that event restore it — otherwise the timer would
	--     prematurely drop the "updating…" indicator on a large/slow repo.
	local function recover(from_timer, subset)
		for _, name in ipairs(subset or names) do
			local p = plugins[name]
			if p and p.status == "updating" then
				p._update_ticks = (p._update_ticks or 0) + 1
				if from_timer and p._update_had_pending and p._update_ticks < 2 then
					-- real update in flight; give it a second timer window before forcing recovery
					vim.defer_fn(function()
						recover(true)
					end, M.update_recover_ms)
				else
					state.update_status(name, p.status_before_update or "installed")
					p.status_before_update = nil
					if not p._update_had_pending then
						-- Mirror finish_update() in build.lua, but only for the genuine
						-- no-op case (nothing was behind before this update): clear
						-- outdated metadata so the dashboard drops any stale "N behind"
						-- badge. On a real failure (from_timer=false) or a timed-out wait
						-- for a real pending update, leave behind/outdated_detail alone --
						-- clearing it here would hide that the plugin is still outdated.
						state.set_behind(name, 0)
						state.set_outdated_detail(name, {})
					end
					p._update_had_pending = nil
					p._update_ticks = nil
				end
			end
		end
		ui_update()
	end

	local function schedule_fallback_recover()
		-- Fallback timer for the no-event case; PackChanged(update) normally
		-- restores status well before this fires.
		vim.defer_fn(function()
			recover(true)
		end, M.update_recover_ms)
	end

	if M.use_git_enabled() then
		-- Partition once: background git handles plain tracking-branch worktrees;
		-- everything else (pins, local, disabled, unknown) rides the final native
		-- pass, which performs their actual transfer there.
		local bg_names, native_names = {}, {}
		for _, name in ipairs(names) do
			if bg_plugin_supported(plugins[name]) then
				table.insert(bg_names, name)
			else
				table.insert(native_names, name)
			end
		end

		local function reconcile_native()
			-- ONE aggregated native pass per <=update_batch_size batch. For
			-- bg-updated plugins the objects are already local, so native is cheap
			-- here (registers plugins + reconciles the lockfile); for skipped ones
			-- it performs the real transfer. PackChanged(update) restores statuses.
			for _, batch in ipairs(M.split_update_batches(native_names, M.update_batch_size)) do
				mark_updating(batch)
				pack._in_pack_op = true
				local ok, err = pcall(pack.native_pack.update, batch, { force = true, silent = true })
				pack._in_pack_op = false
				if not ok then
					vim.notify(
						"pack: update failed for " .. table.concat(batch, ", ") .. ": " .. tostring(err),
						vim.log.levels.ERROR
					)
					recover(false, batch)
				end
			end
			schedule_fallback_recover()
		end

		local total = #bg_names
		if total == 0 then
			reconcile_native()
			return
		end

		local idx, inflight, completed = 0, 0, 0
		local pumping = false
		local function pump()
			if pumping then
				return
			end
			pumping = true
			while inflight < M.max_concurrency and idx < total do
				idx = idx + 1
				inflight = inflight + 1
				local name = bg_names[idx]
				mark_updating({ name })

				M.bg_update_one(plugins[name], function(ok)
					inflight = inflight - 1
					completed = completed + 1
					if ok then
						-- Background git already moved HEAD; queue a cheap native pass.
						table.insert(native_names, name)
					else
						vim.notify(
							"pack: background update failed for " .. name .. " - see the plugin's log",
							vim.log.levels.ERROR
						)
						recover(false, { name })
					end

					if completed == total then
						reconcile_native()
					else
						vim.schedule(pump)
					end
				end)
			end
			pumping = false
		end
		pump()
		return
	end

	local batches = M.split_update_batches(names, M.update_batch_size)
	local i = 1
	local function update_next()
		if i > #batches then
			schedule_fallback_recover()
			return
		end

		local batch = batches[i]
		mark_updating(batch)
		pack._in_pack_op = true
		local ok, err = pcall(pack.native_pack.update, batch, { force = true, silent = true })
		pack._in_pack_op = false

		if not ok then
			vim.notify(
				"pack: update failed for " .. table.concat(batch, ", ") .. ": " .. tostring(err),
				vim.log.levels.ERROR
			)
			recover(false, batch)
		end

		i = i + 1
		vim.defer_fn(update_next, 10)
	end
	update_next()
end

return M
