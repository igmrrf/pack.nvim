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

-- Run a git command asynchronously (vim.system), logging output to the plugin.
-- on_done(code, stdout) is invoked on the main loop.
local function git(plugin, args, cwd, on_done)
	append_log(plugin, "$ git " .. table.concat(args, " "))
	local cmd = { "git" }
	for _, a in ipairs(args) do
		cmd[#cmd + 1] = a
	end
	-- vim.system raises synchronously if cwd doesn't exist; treat that as a
	-- failed command rather than propagating.
	local ok, err = pcall(vim.system, cmd, { cwd = cwd, text = true, timeout = M.git_timeout }, function(res)
		vim.schedule(function()
			local out = res.stdout or ""
			local combined = out
			if res.stderr and res.stderr ~= "" then
				combined = combined .. "\n" .. res.stderr
			end
			for line in combined:gmatch("[^\r\n]+") do
				append_log(plugin, line)
			end
			on_done(res.code, out)
		end)
	end)
	if not ok then
		append_log(plugin, "failed to spawn git: " .. tostring(err))
		vim.schedule(function()
			on_done(-1, "")
		end)
	end
end

-- Pure parsers (unit-tested) ------------------------------------------------

function M.parse_behind_count(output)
	if type(output) ~= "string" then
		return nil
	end
	local digits = output:match("^%s*(%d+)%s*$")
	if not digits then
		return nil
	end
	return tonumber(digits)
end

function M.parse_revision_pair(output)
	if type(output) ~= "string" then
		return nil, nil
	end
	local lines = {}
	for line in output:gmatch("([^\r\n]+)") do
		table.insert(lines, line)
	end
	return lines[1], lines[2]
end

function M.parse_upstream_branch_name(output)
	if type(output) ~= "string" then
		return nil
	end
	local trimmed = vim.trim(output)
	if trimmed == "" then
		return nil
	end
	return trimmed:match("^[^/]-/(.+)$") or trimmed
end

function M.parse_pending_commits(output)
	if type(output) ~= "string" or output == "" then
		return {}
	end
	local commits = {}
	for line in output:gmatch("([^\r\n]+)") do
		table.insert(commits, line)
	end
	return commits
end

-- Outdated check ------------------------------------------------------------
-- Native vim.pack has no non-mutating "am I behind upstream?" query, so we keep
-- a lightweight read-only git probe purely to drive the dashboard indicator.

-- Native vim.pack leaves plugins in a DETACHED HEAD (checked out at
-- origin/<ref>), so `@{upstream}` doesn't exist. Resolve the ref to compare
-- HEAD against: a branch-pinned plugin tracks origin/<branch>; an unpinned
-- plugin tracks the remote's default branch (origin/HEAD). A plugin pinned to a
-- tag/commit/version range has no "newer commits on the branch" notion, so
-- return nil to skip it.
-- Async: resolves the upstream ref via `cb(ref_or_nil)`. Branch-pinned and
-- fully-pinned (tag/commit/version) cases answer immediately; the unpinned case
-- spawns a non-blocking `git symbolic-ref` instead of blocking the UI thread.
function M.upstream_ref(plugin, dir, cb)
	if plugin.branch then
		return cb("origin/" .. plugin.branch)
	end
	if plugin.tag or plugin.commit or plugin.version or plugin.sem_version then
		return cb(nil)
	end
	git(plugin, { "symbolic-ref", "--short", "refs/remotes/origin/HEAD" }, dir, function(code, out)
		if code == 0 then
			local ref = vim.trim(out or "")
			if ref ~= "" then
				return cb(ref)
			end
		end
		cb(nil)
	end)
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

-- Max concurrent git probes and how long (seconds) a plugin's outdated result
-- stays fresh before check_all_outdated will re-probe it.
M.max_concurrency = 8
M.outdated_cooldown = 300

-- Run `worker(item, done)` over items with at most `limit` in flight. `worker`
-- must call `done` exactly once when its (async) work finishes. This is what
-- keeps a large config from launching N simultaneous `git fetch` processes.
function M.run_queued(items, worker, limit)
	limit = limit or M.max_concurrency
	local idx, inflight = 0, 0
	-- `pumping` collapses a synchronously-completing worker (e.g. check_outdated
	-- bailing before spawning git) into the running loop instead of recursing:
	-- its inline done() decrements inflight and the re-entrant pump() returns
	-- immediately, letting the outer while pick up the freed slot. Without this,
	-- N sync completions recurse N deep and can overflow the stack.
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

-- Plugins eligible for an outdated re-check: installed/loaded, not disabled, and
-- not checked within the cooldown window (so re-opening the dashboard doesn't
-- re-fetch everything every time).
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

function M.check_all_outdated()
	M.run_queued(M.outdated_targets(), function(p, done)
		begin_activity()
		M.check_outdated(p, function()
			end_activity()
			done()
		end)
	end, M.max_concurrency)
end

-- Build hooks ---------------------------------------------------------------

-- Run a single build step, then call cb(). Mirrors lazy.nvim's build forms:
--   * function        -> called with the plugin context
--   * ":SomeCommand"  -> run as a Vim ex-command
--   * "shell string"  -> run through the shell (sh, or cmd.exe on Windows)
local function run_build_step(plugin, hook, cb)
	if type(hook) == "function" then
		vim.schedule(function()
			local ok, err = pcall(hook, { path = plugin.dir, spec = plugin })
			if not ok then
				append_log(plugin, "build hook failed: " .. tostring(err))
				vim.notify("pack: build hook failed for " .. plugin.name .. "\n" .. tostring(err), vim.log.levels.ERROR)
				cb(false)
			else
				cb(true)
			end
		end)
	elseif type(hook) == "string" and hook:sub(1, 1) == ":" then
		-- Vim ex-command form, e.g. build = ":TSUpdate".
		vim.schedule(function()
			append_log(plugin, "$ " .. hook)
			if plugin.dir and vim.fn.isdirectory(plugin.dir) == 1 then
				vim.opt.rtp:append(plugin.dir)
				local plugin_dir = plugin.dir .. "/plugin"
				if vim.fn.isdirectory(plugin_dir) == 1 then
					for _, f in ipairs(vim.fn.glob(plugin_dir .. "/**/*.{vim,lua}", false, true)) do
						pcall(vim.cmd, "source " .. f)
					end
				end
			end
			local ok, err = pcall(vim.cmd, hook:sub(2))
			if not ok then
				append_log(plugin, "build command failed: " .. tostring(err))
				vim.notify(
					"pack: build command failed for " .. plugin.name .. ": " .. tostring(err),
					vim.log.levels.ERROR
				)
				cb(false)
			else
				cb(true)
			end
		end)
	elseif type(hook) == "string" then
		-- SECURITY: a shell build hook runs verbatim (arbitrary shell). Trusted-spec
		-- only, never a remote/lockfile value - same model as lazy.nvim. On Windows
		-- there is no `sh`, so use cmd.exe.
		local shell = vim.fn.has("win32") == 1 and { "cmd", "/c", hook } or { "sh", "-c", hook }
		append_log(plugin, "$ " .. table.concat(shell, " "))
		-- vim.system raises SYNCHRONOUSLY if cwd doesn't exist (e.g. :Pack build on
		-- a registered-but-not-installed plugin). The git() helper pcall-guards for
		-- this reason; the shell build path must too, or the throw escapes the
		-- PackChanged autocmd / :Pack command.
		local ok, err = pcall(vim.system, shell, { cwd = plugin.dir, text = true }, function(res)
			vim.schedule(function()
				local combined = (res.stdout or "")
				if res.stderr and res.stderr ~= "" then
					combined = combined .. "\n" .. res.stderr
				end
				for line in combined:gmatch("[^\r\n]+") do
					append_log(plugin, line)
				end
				if res.code ~= 0 then
					append_log(plugin, "build hook exit code: " .. tostring(res.code))
					vim.notify(
						"pack: build hook failed for " .. plugin.name .. " (exit " .. tostring(res.code) .. ")",
						vim.log.levels.ERROR
					)
					cb(false)
				else
					cb(true)
				end
			end)
		end)
		if not ok then
			append_log(plugin, "could not run build hook: " .. tostring(err))
			vim.notify(
				"pack: could not run build hook for " .. plugin.name .. ": " .. tostring(err),
				vim.log.levels.ERROR
			)
			cb(false)
		end
	else
		cb(true)
	end
end

-- Run a plugin's `build` hook. Accepts a function, a string (":Cmd" or shell),
-- or a list of any of those run in sequence, and calls done_cb() exactly once
-- when all steps finish. Matches lazy.nvim's build spec.
function M.run_build_hook(plugin, done_cb)
	done_cb = done_cb or function() end
	local build = plugin.build
	if not build then
		return done_cb()
	end

	local status_before = plugin.status
	state.update_status(plugin.name, "building")
	plugin.status = "building"
	ui_update()
	if package.loaded["pack.ui"] then
		require("pack.ui").ensure_spinner()
	end

	local steps = type(build) == "table" and build or { build }
	local i = 0
	local build_failed = false
	local function next_step(step_ok)
		if step_ok == false then
			build_failed = true
		end
		i = i + 1
		if i > #steps then
			local target_status = build_failed and "error" or (status_before or "installed")
			state.update_status(plugin.name, target_status)
			plugin.status = target_status
			ui_update()
			return done_cb()
		end
		run_build_step(plugin, steps[i], next_step)
	end
	next_step(true)
end

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

	local lines = { "  Pack Pending Updates Diff", "  =========================", "" }
	if #outdated == 0 then
		table.insert(lines, "  No pending updates or outdated plugins found.")
		table.insert(lines, "  (Press 'c' in :Pack to query upstream updates first)")
	else
		for _, p in ipairs(outdated) do
			local branch_info = p.upstream_branch and (" (" .. p.upstream_branch .. ")") or ""
			table.insert(lines, string.format("  • %s — %d commit(s) behind%s", p.name, p.behind, branch_info))
			if p.revision_before and p.revision_after then
				table.insert(lines, string.format("    Revision: %s -> %s", p.revision_before, p.revision_after))
			end
			if p.pending_commits and #p.pending_commits > 0 then
				for _, commit in ipairs(p.pending_commits) do
					table.insert(lines, "    " .. commit)
				end
			end
			table.insert(lines, "")
		end
	end

	if package.loaded["pack.ui"] then
		local buf = require("pack.ui").open_popup(
			lines,
			{ height_pct = 0.6, width_pct = 0.7, close_keys = { "q", "d", "<Esc>" } }
		)
		vim.bo[buf].filetype = "pack_diff"
	end
end

-- Register a PackChanged autocmd that runs build hooks after native installs or
-- updates a plugin. Must be called before vim.pack.add so initial-install
-- events aren't missed.
function M.setup_build_hooks()
	local group = vim.api.nvim_create_augroup("pack_build_hooks", { clear = true })
	vim.api.nvim_create_autocmd("PackChanged", {
		group = group,
		callback = function(ev)
			local d = ev.data
			if not d or (d.kind ~= "install" and d.kind ~= "update") then
				return
			end
			local name = d.spec and d.spec.name
			local p = name and state.get_plugins()[name]
			if not p then
				return
			end
			-- load_fn also sets p.dir, but PackChanged(install) fires before it, so
			-- take the path straight from the event.
			p.dir = d.path or p.dir
			local function finish_update()
				if d.kind == "update" then
					if p.status_before_update and p.status ~= "error" then
						state.update_status(name, p.status_before_update)
						p.status_before_update = nil
					end
					state.set_behind(name, 0)
					state.set_outdated_detail(name, {})
					ui_update()
				end
			end

			local function maybe_build()
				if p.build then
					M.run_build_hook(p, finish_update)
				else
					finish_update()
				end
			end

			-- Native vim.pack does not recurse submodules on INSTALL (it does on
			-- update). Initialize them first, and only run the build hook once they
			-- have populated -- a build that compiles submodule sources would
			-- otherwise race an empty/partial tree. Gate the build behind the
			-- submodule callback rather than firing both concurrently.
			if d.kind == "install" and p.dir and vim.fn.filereadable(p.dir .. "/.gitmodules") == 1 then
				append_log(p, "$ git submodule update --init --recursive")
				local ok = pcall(
					vim.system,
					{ "git", "submodule", "update", "--init", "--recursive" },
					{ cwd = p.dir },
					function(res)
						vim.schedule(function()
							if res.code ~= 0 then
								vim.notify(
									"pack: submodule init failed for "
										.. p.name
										.. " (exit "
										.. tostring(res.code)
										.. ")",
									vim.log.levels.WARN
								)
							end
							maybe_build()
						end)
					end
				)
				if not ok then
					maybe_build()
				end
			else
				maybe_build()
			end
		end,
	})
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
