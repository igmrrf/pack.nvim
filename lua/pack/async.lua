local state = require("pack.state")

local M = {}

M.max_jobs = 4
M.max_log_lines = 500
local queue = {}
local active_jobs = 0

local function append_log(plugin, line)
  table.insert(plugin.log, line)
  if #plugin.log > M.max_log_lines then
    table.remove(plugin.log, 1)
  end
end

local function process_queue()
  if active_jobs >= M.max_jobs or #queue == 0 then
    if active_jobs == 0 and #queue == 0 then
      if package.loaded["pack.loader"] then
        pcall(require("pack.loader").build_cache)
      end
    end
    return
  end
  
  local job = table.remove(queue, 1)
  active_jobs = active_jobs + 1
  
  job(function()
    active_jobs = active_jobs - 1
    process_queue()
  end)
  
  process_queue()
end

function M.spawn(plugin, cmd, args, cwd, capture_output, on_exit)
  if type(capture_output) == "function" then
    on_exit = capture_output
    capture_output = false
  end

  local stdout = vim.uv.new_pipe()
  local stderr = vim.uv.new_pipe()

  append_log(plugin, "$ " .. cmd .. " " .. table.concat(args, " "))

  local captured_stdout = {}
  local exit_code = nil
  local pipes_closed = 0
  local handle

  local function check_done()
    if exit_code ~= nil and pipes_closed == 2 then
      if handle and not handle:is_closing() then handle:close() end
      if type(on_exit) == "function" then
        vim.schedule(function()
          on_exit(exit_code, table.concat(captured_stdout, "\n"))
        end)
      end
    end
  end

  local function make_on_read(pipe, is_stdout)
    local buf = ""
    return function(err, data)
      if err or not data then
        if buf ~= "" then
          local last = buf:gsub("\r+$", ""):match("([^\r]*)$")
          if last and last ~= "" then
            vim.schedule(function() append_log(plugin, last) end)
            if is_stdout and capture_output then
              table.insert(captured_stdout, last)
            end
          end
        end
        pipe:read_stop()
        pipe:close()
        pipes_closed = pipes_closed + 1
        check_done()
        return
      end
      
      buf = buf .. data
      local lines_to_log = {}
      
      while true do
        local line_end = buf:find("\n")
        if not line_end then break end
        local line = buf:sub(1, line_end - 1)
        buf = buf:sub(line_end + 1)
        
        local last = line:gsub("\r+$", ""):match("([^\r]*)$")
        if last and last ~= "" then
          table.insert(lines_to_log, last)
          if is_stdout and capture_output then
            table.insert(captured_stdout, last)
          end
        end
      end
      
      if #lines_to_log > 0 then
        vim.schedule(function()
          for _, l in ipairs(lines_to_log) do
            append_log(plugin, l)
          end
        end)
      end
    end
  end

  handle = vim.uv.spawn(cmd, {
    args = args,
    cwd = cwd,
    stdio = { nil, stdout, stderr }
  }, function(code, signal)
    exit_code = code
    check_done()
  end)

  if not handle then
    stdout:close()
    stderr:close()
    append_log(plugin, "Failed to spawn " .. cmd)
    vim.schedule(function()
      if type(on_exit) == "function" then on_exit(-1, "") end
    end)
    return
  end

  stdout:read_start(make_on_read(stdout, true))
  stderr:read_start(make_on_read(stderr, false))
end

local function run_build_hook(plugin, done_cb)
  if not plugin.build then
    return done_cb()
  end
  if type(plugin.build) == "function" then
    vim.schedule(function()
      local ok, err = pcall(plugin.build, { path = plugin.dir, spec = plugin })
      if not ok then vim.notify("pack: build hook failed for " .. plugin.name .. "\n" .. tostring(err), vim.log.levels.ERROR) end
      done_cb()
    end)
  elseif type(plugin.build) == "string" then
    -- SECURITY: a string build hook is executed verbatim via `sh -c`. This is
    -- arbitrary shell, same trust model as lazy.nvim: only ever comes from the
    -- user's own trusted plugin spec, never from a remote/lockfile value.
    M.spawn(plugin, "sh", { "-c", plugin.build }, plugin.dir, function(code)
      if code ~= 0 then
        vim.schedule(function() vim.notify("pack: build hook failed for " .. plugin.name .. " with code " .. tostring(code), vim.log.levels.ERROR) end)
      end
      done_cb()
    end)
  else
    done_cb()
  end
end

M.run_build_hook = run_build_hook

function M.install(plugin)
  table.insert(queue, function(done)
    state.update_status(plugin.name, "installing")
    if package.loaded["pack.ui"] then
      require("pack.ui").update()
    end
    
    local parent_dir = vim.fn.fnamemodify(plugin.dir, ":h")
    vim.fn.mkdir(parent_dir, "p")
    
    local clone_args = { "clone", "--depth", "1" }
    if plugin.branch then
      table.insert(clone_args, "--branch")
      table.insert(clone_args, plugin.branch)
    elseif plugin.tag then
      table.insert(clone_args, "--branch")
      table.insert(clone_args, plugin.tag)
    end
    table.insert(clone_args, plugin.url)
    table.insert(clone_args, plugin.dir)

    M.spawn(plugin, "git", clone_args, nil, function(code)
      if code == 0 then
        local lock = require("pack.lock")
        local target_commit = plugin.commit or lock.get_commit(plugin.name)

        local function finalize_install()
          run_build_hook(plugin, function()
            state.update_status(plugin.name, "installed")
            if not plugin.lazy then
              vim.schedule(function()
                require("pack.loader").load(plugin.name)
              end)
            else
              vim.schedule(function()
                require("pack.loader").setup_triggers(plugin)
              end)
            end
            done()
            if package.loaded["pack.ui"] then
              require("pack.ui").update()
            end
          end)
        end

        local function do_checkout()
          if target_commit then
            M.spawn(plugin, "git", { "fetch", "origin", target_commit, "--depth", "1" }, plugin.dir, function()
              M.spawn(plugin, "git", { "checkout", target_commit, "--" }, plugin.dir, function()
                finalize_install()
              end)
            end)
          else
            M.spawn(plugin, "git", { "rev-parse", "HEAD" }, plugin.dir, true, function(rev_code, output)
              if rev_code == 0 and output then
                local hash = output:match("([^\r\n]+)")
                if hash then lock.set_commit(plugin.name, hash, plugin.url) end
              end
              finalize_install()
            end)
          end
        end

        if plugin.version or plugin.sem_version then
          local range_str = plugin.version or plugin.sem_version
          local ok, range
          if type(range_str) == "table" and range_str.has then
            range = range_str
          else
            ok, range = pcall(vim.version.range, range_str)
          end
          if range then
            M.spawn(plugin, "git", { "fetch", "--tags" }, plugin.dir, function()
              M.spawn(plugin, "git", { "tag" }, plugin.dir, true, function(tcode, tout)
                if tcode == 0 and tout then
                  local best_v = nil
                  local best_tag = nil
                  for line in tout:gmatch("[^\r\n]+") do
                    local parsed = vim.version.parse(line)
                    if parsed and range:has(parsed) then
                      if not best_v or vim.version.cmp(parsed, best_v) > 0 then
                        best_v = parsed
                        best_tag = line
                      end
                    end
                  end
                  if best_tag then
                    plugin.tag = best_tag
                    M.spawn(plugin, "git", { "checkout", best_tag, "--" }, plugin.dir, function()
                      do_checkout()
                    end)
                    return
                  end
                end
                do_checkout()
              end)
            end)
            return
          end
        end
        do_checkout()
      else
        state.update_status(plugin.name, "error")
        done()
        if package.loaded["pack.ui"] then
          require("pack.ui").update()
        end
      end
    end)
  end)
  process_queue()
end

function M.update_plugin(plugin)
  local was_loaded = plugin.status == "loaded"
  table.insert(queue, function(done)
    state.update_status(plugin.name, "updating")
    if package.loaded["pack.ui"] then
      require("pack.ui").update()
    end

    local function fail()
      state.update_status(plugin.name, "error")
      done()
      if package.loaded["pack.ui"] then
        require("pack.ui").update()
      end
    end

    -- Record the resolved HEAD into the lockfile, run the build hook, then
    -- settle status. Called after the working tree is already at its target.
    local function record_and_finish()
      M.spawn(plugin, "git", { "rev-parse", "HEAD" }, plugin.dir, true, function(rev_code, output)
        if rev_code == 0 and output then
          local hash = output:match("([^\r\n]+)")
          if hash then
            require("pack.lock").set_commit(plugin.name, hash, plugin.url)
          end
        end
        run_build_hook(plugin, function()
          state.update_status(plugin.name, was_loaded and "loaded" or "installed")
          state.set_behind(plugin.name, 0)
          state.set_outdated_detail(plugin.name, {})
          done()
          if package.loaded["pack.ui"] then
            require("pack.ui").update()
          end
        end)
      end)
    end

    if plugin.commit or plugin.tag then
      -- Pinned to a fixed commit/tag: fetch the ref and check it out. Do NOT
      -- `git pull --rebase` afterwards - that fails on the detached HEAD a
      -- commit/tag checkout leaves us in and would defeat the pin anyway.
      local ref = plugin.commit or plugin.tag
      local fetch_args = plugin.tag and { "fetch", "origin", "--tags" } or { "fetch", "origin", ref }
      M.spawn(plugin, "git", fetch_args, plugin.dir, function()
        M.spawn(plugin, "git", { "checkout", ref, "--" }, plugin.dir, function(code)
          if code == 0 then record_and_finish() else fail() end
        end)
      end)
    else
      -- Tracking a branch (or the default branch): move to the branch tip.
      local function pull()
        M.spawn(plugin, "git", { "pull", "--rebase" }, plugin.dir, function(code)
          if code == 0 then record_and_finish() else fail() end
        end)
      end
      if plugin.branch then
        M.spawn(plugin, "git", { "checkout", plugin.branch, "--" }, plugin.dir, function(code)
          if code == 0 then pull() else fail() end
        end)
      else
        pull()
      end
    end
  end)
  process_queue()
end

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

function M.check_outdated(plugin)
  -- Skip if plugin is disabled or not in an eligible status
  if plugin.disabled or (plugin.status ~= "installed" and plugin.status ~= "loaded") then
    return
  end
  table.insert(queue, function(done)
    M.spawn(plugin, "git", { "fetch" }, plugin.dir, function(fetch_code)
      if fetch_code ~= 0 then
        state.update_status(plugin.name, "error")
        state.set_outdated_detail(plugin.name, { error = "Upstream fetch failed" })
        if package.loaded["pack.ui"] then
          require("pack.ui").update()
        end
        done()
        return
      end
      M.spawn(plugin, "git", { "rev-list", "--count", "HEAD..@{upstream}" }, plugin.dir, true, function(count_code, output)
        if count_code ~= 0 then
          done()
          return
        end
        local behind = M.parse_behind_count(output)
        if not behind then
          done()
          return
        end
        state.set_behind(plugin.name, behind)
        if package.loaded["pack.ui"] then
          require("pack.ui").update()
        end

        if behind == 0 then
          state.set_outdated_detail(plugin.name, {})
          done()
          return
        end

        -- Note: `git rev-parse --short HEAD @{upstream}` (both revs after a
        -- single --short) fails with "fatal: Needed a single revision" on
        -- real git; --short only tolerates one rev argument at a time.
        -- Resolve full hashes instead and truncate them ourselves.
        M.spawn(plugin, "git", { "rev-parse", "HEAD", "@{upstream}" }, plugin.dir, true, function(rev_code, rev_output)
          local revision_before, revision_after
          if rev_code == 0 then
            local full_before, full_after = M.parse_revision_pair(rev_output)
            revision_before = full_before and full_before:sub(1, 7)
            revision_after = full_after and full_after:sub(1, 7)
          end

          M.spawn(plugin, "git", { "rev-parse", "--abbrev-ref", "@{upstream}" }, plugin.dir, true, function(branch_code, branch_output)
            local upstream_branch
            if branch_code == 0 then
              upstream_branch = M.parse_upstream_branch_name(branch_output)
            end

            M.spawn(plugin, "git", { "log", "--format=%h │ %s", "HEAD..@{upstream}" }, plugin.dir, true, function(log_code, log_output)
              local pending_commits = {}
              if log_code == 0 then
                pending_commits = M.parse_pending_commits(log_output)
              end
              state.set_outdated_detail(plugin.name, {
                revision_before = revision_before,
                revision_after = revision_after,
                upstream_branch = upstream_branch,
                pending_commits = pending_commits,
              })
              if package.loaded["pack.ui"] then
                require("pack.ui").update()
              end
              done()
            end)
          end)
        end)
      end)
    end)
  end)
  process_queue()
end

function M.check_all_outdated()
  for _, p in pairs(state.get_plugins()) do
    if not p.disabled and (p.status == "installed" or p.status == "loaded") then
      M.check_outdated(p)
    end
  end
end

-- Install only plugins that aren't on disk yet. Unlike sync(), this never
-- pulls updates for already-installed plugins - safe to run on every startup.
function M.install_missing()
  for _, p in pairs(state.get_plugins()) do
    if not p.disabled and p.status == "missing" then
      p.log = {}
      M.install(p)
    end
  end
end

function M.sync(config)
  for _, p in pairs(state.get_plugins()) do
    if p.disabled then
      -- skip
    elseif p.status == "installing" or p.status == "updating" then
      -- Skip already active jobs
    else
      p.log = {}
      if p.status == "missing" then
        M.install(p)
      elseif p.status == "installed" or p.status == "loaded" or p.status == "error" then
        -- If it errored, it might be an incomplete clone or pull error,
        -- but update_plugin (pull) is safer if dir exists, otherwise install
        if vim.fn.isdirectory(p.dir) == 1 then
          M.update_plugin(p)
        else
          M.install(p)
        end
      end
    end
  end
end

function M.restore()
  for _, p in pairs(state.get_plugins()) do
    if p.disabled then
      -- skip
    elseif p.status == "installing" or p.status == "updating" or p.status == "missing" then
      -- skip
    else
      local target_commit = require("pack.lock").get_commit(p.name)
      if target_commit then
        table.insert(queue, function(done)
          state.update_status(p.name, "updating")
          if package.loaded["pack.ui"] then require("pack.ui").update() end

          M.spawn(p, "git", { "fetch", "origin", target_commit }, p.dir, function()
            M.spawn(p, "git", { "checkout", target_commit, "--" }, p.dir, function(code)
              if code == 0 then
                state.update_status(p.name, "installed")
                state.set_behind(p.name, 0)
                state.set_outdated_detail(p.name, {})
              else
                state.update_status(p.name, "error")
              end
              done()
              if package.loaded["pack.ui"] then require("pack.ui").update() end
            end)
          end)
        end)
      end
    end
  end
  process_queue()
end

return M
