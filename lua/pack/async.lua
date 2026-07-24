local state = require("pack.state")

local M = {}

M.max_log_lines = 500

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
  local ok, err = pcall(vim.system, cmd, { cwd = cwd, text = true }, function(res)
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
    vim.schedule(function() on_done(-1, "") end)
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
    if finished then return end
    finished = true
    done()
  end

  if plugin.disabled or (plugin.status ~= "installed" and plugin.status ~= "loaded") then
    return finish()
  end
  local dir = plugin.dir
  if not dir or dir == "" or vim.fn.isdirectory(dir) == 0 then
    return finish()
  end

  git(plugin, { "fetch" }, dir, function(fetch_code)
    if fetch_code ~= 0 then
      state.update_status(plugin.name, "error")
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
  local function pump()
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
    if not p.disabled and (p.status == "installed" or p.status == "loaded") then
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
        vim.notify("pack: build hook failed for " .. plugin.name .. "\n" .. tostring(err), vim.log.levels.ERROR)
      end
      cb()
    end)
  elseif type(hook) == "string" and hook:sub(1, 1) == ":" then
    -- Vim ex-command form, e.g. build = ":TSUpdate".
    vim.schedule(function()
      append_log(plugin, "$ " .. hook)
      local ok, err = pcall(vim.cmd, hook:sub(2))
      if not ok then
        vim.notify("pack: build command failed for " .. plugin.name .. ": " .. tostring(err), vim.log.levels.ERROR)
      end
      cb()
    end)
  elseif type(hook) == "string" then
    -- SECURITY: a shell build hook runs verbatim (arbitrary shell). Trusted-spec
    -- only, never a remote/lockfile value - same model as lazy.nvim. On Windows
    -- there is no `sh`, so use cmd.exe.
    local shell = vim.fn.has("win32") == 1 and { "cmd", "/c", hook } or { "sh", "-c", hook }
    append_log(plugin, "$ " .. table.concat(shell, " "))
    vim.system(shell, { cwd = plugin.dir, text = true }, function(res)
      vim.schedule(function()
        local combined = (res.stdout or "")
        if res.stderr and res.stderr ~= "" then
          combined = combined .. "\n" .. res.stderr
        end
        for line in combined:gmatch("[^\r\n]+") do
          append_log(plugin, line)
        end
        if res.code ~= 0 then
          vim.notify(
            "pack: build hook failed for " .. plugin.name .. " (exit " .. tostring(res.code) .. ")",
            vim.log.levels.ERROR
          )
        end
        cb()
      end)
    end)
  else
    cb()
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

  local steps = type(build) == "table" and build or { build }
  local i = 0
  local function next_step()
    i = i + 1
    if i > #steps then
      return done_cb()
    end
    run_build_step(plugin, steps[i], next_step)
  end
  next_step()
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
      -- Native vim.pack does not recurse submodules; initialize them on install
      -- so plugins that ship submodules are complete before their build hook.
      if d.kind == "install" and p.dir and vim.fn.filereadable(p.dir .. "/.gitmodules") == 1 then
        vim.system({ "git", "submodule", "update", "--init", "--recursive" }, { cwd = p.dir })
      end
      if p.build then
        M.run_build_hook(p)
      end
      -- After an update the plugin is at the new revision: clear the stale
      -- outdated indicators and refresh the dashboard.
      if d.kind == "update" then
        if p.status_before_update then
          state.update_status(name, p.status_before_update)
          p.status_before_update = nil
        end
        state.set_behind(name, 0)
        state.set_outdated_detail(name, {})
        ui_update()
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
