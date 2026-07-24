local state = require("pack.state")

local M = {}

M.max_log_lines = 500

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
function M.upstream_ref(plugin, dir)
  if plugin.branch then
    return "origin/" .. plugin.branch
  end
  if plugin.tag or plugin.commit or plugin.version or plugin.sem_version then
    return nil
  end
  local out = vim.fn.system({ "git", "-C", dir, "symbolic-ref", "--short", "refs/remotes/origin/HEAD" })
  if vim.v.shell_error == 0 then
    local ref = vim.trim(out)
    if ref ~= "" then
      return ref
    end
  end
  return nil
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

    local ref = M.upstream_ref(plugin, dir)
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
  end)
end

function M.check_all_outdated()
  for _, p in pairs(state.get_plugins()) do
    if not p.disabled and (p.status == "installed" or p.status == "loaded") then
      begin_activity()
      M.check_outdated(p, end_activity)
    end
  end
end

-- Build hooks ---------------------------------------------------------------

function M.run_build_hook(plugin, done_cb)
  done_cb = done_cb or function() end
  if not plugin.build then
    return done_cb()
  end

  if type(plugin.build) == "function" then
    vim.schedule(function()
      local ok, err = pcall(plugin.build, { path = plugin.dir, spec = plugin })
      if not ok then
        vim.notify("pack: build hook failed for " .. plugin.name .. "\n" .. tostring(err), vim.log.levels.ERROR)
      end
      done_cb()
    end)
  elseif type(plugin.build) == "string" then
    -- SECURITY: a string build hook runs verbatim via `sh -c` (arbitrary
    -- shell). Trusted-spec only, never a remote/lockfile value - same model as
    -- lazy.nvim.
    append_log(plugin, "$ sh -c " .. plugin.build)
    vim.system({ "sh", "-c", plugin.build }, { cwd = plugin.dir, text = true }, function(res)
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
        done_cb()
      end)
    end)
  else
    done_cb()
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
  pack.native_pack.update(names, { force = true })
end

return M
