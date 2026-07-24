local state = require("packui.state")

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

function M.spawn(plugin, cmd, args, cwd, on_exit)
  local stdout = vim.uv.new_pipe()
  local stderr = vim.uv.new_pipe()

  append_log(plugin, "$ " .. cmd .. " " .. table.concat(args, " "))

  local captured_stdout = {}

  local handle
  handle = vim.uv.spawn(cmd, {
    args = args,
    cwd = cwd,
    stdio = { nil, stdout, stderr }
  }, function(code, signal)
    stdout:read_stop()
    stderr:read_stop()
    stdout:close()
    stderr:close()
    handle:close()
    vim.schedule(function()
      if on_exit then on_exit(code, table.concat(captured_stdout, "\n")) end
    end)
  end)

  if not handle then
    stdout:close()
    stderr:close()
    append_log(plugin, "Failed to spawn " .. cmd)
    vim.schedule(function()
      if on_exit then on_exit(-1, "") end
    end)
    return
  end

  local function make_on_read(is_stdout)
    return function(err, data)
      if data then
        vim.schedule(function()
          for line in data:gmatch("([^\n]+)") do
            -- collapse carriage-return progress updates (e.g. git clone %) to the last segment
            local last = line:match("([^\r]*)$")
            if last ~= "" then
              append_log(plugin, last)
              if is_stdout then
                table.insert(captured_stdout, last)
              end
            end
          end
        end)
      end
    end
  end

  stdout:read_start(make_on_read(true))
  stderr:read_start(make_on_read(false))
end

function M.install(plugin)
  table.insert(queue, function(done)
    state.update_status(plugin.name, "installing")
    if package.loaded["packui.ui"] then
      require("packui.ui").update()
    end
    
    local parent_dir = vim.fn.fnamemodify(plugin.dir, ":h")
    vim.fn.mkdir(parent_dir, "p")
    
    M.spawn(plugin, "git", { "clone", "--depth", "1", plugin.url, plugin.dir }, nil, function(code)
      if code == 0 then
        local lock = require("packui.lock")
        local target_commit = lock.get_commit(plugin.name)

        local function finalize_install()
          state.update_status(plugin.name, "installed")
          if not plugin.lazy then
            vim.schedule(function()
              require("packui.loader").load(plugin.name)
            end)
          else
            vim.schedule(function()
              require("packui.loader").setup_triggers(plugin)
            end)
          end
          done()
          if package.loaded["packui.ui"] then
            require("packui.ui").update()
          end
        end

        if target_commit then
          M.spawn(plugin, "git", { "fetch", "origin", target_commit, "--depth", "1" }, plugin.dir, function()
            M.spawn(plugin, "git", { "checkout", target_commit }, plugin.dir, function()
              finalize_install()
            end)
          end)
        else
          M.spawn(plugin, "git", { "rev-parse", "HEAD" }, plugin.dir, function(rev_code, output)
            if rev_code == 0 and output then
              local hash = output:match("([^\r\n]+)")
              if hash then lock.set_commit(plugin.name, hash, plugin.url) end
            end
            finalize_install()
          end)
        end
      else
        state.update_status(plugin.name, "error")
        done()
        if package.loaded["packui.ui"] then
          require("packui.ui").update()
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
    if package.loaded["packui.ui"] then
      require("packui.ui").update()
    end

    M.spawn(plugin, "git", { "pull", "--rebase" }, plugin.dir, function(code)
      if code == 0 then
        M.spawn(plugin, "git", { "rev-parse", "HEAD" }, plugin.dir, function(rev_code, output)
          if rev_code == 0 and output then
            local hash = output:match("([^\r\n]+)")
            if hash then
              require("packui.lock").set_commit(plugin.name, hash, plugin.url)
            end
          end
          state.update_status(plugin.name, was_loaded and "loaded" or "installed")
          state.set_behind(plugin.name, 0)
          state.set_outdated_detail(plugin.name, {})
          done()
          if package.loaded["packui.ui"] then
            require("packui.ui").update()
          end
        end)
      else
        state.update_status(plugin.name, "error")
        done()
        if package.loaded["packui.ui"] then
          require("packui.ui").update()
        end
      end
    end)
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
        done()
        return
      end
      M.spawn(plugin, "git", { "rev-list", "--count", "HEAD..@{upstream}" }, plugin.dir, function(count_code, output)
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
        if package.loaded["packui.ui"] then
          require("packui.ui").update()
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
        M.spawn(plugin, "git", { "rev-parse", "HEAD", "@{upstream}" }, plugin.dir, function(rev_code, rev_output)
          local revision_before, revision_after
          if rev_code == 0 then
            local full_before, full_after = M.parse_revision_pair(rev_output)
            revision_before = full_before and full_before:sub(1, 7)
            revision_after = full_after and full_after:sub(1, 7)
          end

          M.spawn(plugin, "git", { "rev-parse", "--abbrev-ref", "@{upstream}" }, plugin.dir, function(branch_code, branch_output)
            local upstream_branch
            if branch_code == 0 then
              upstream_branch = M.parse_upstream_branch_name(branch_output)
            end

            M.spawn(plugin, "git", { "log", "--format=%h │ %s", "HEAD..@{upstream}" }, plugin.dir, function(log_code, log_output)
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
              if package.loaded["packui.ui"] then
                require("packui.ui").update()
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
      local target_commit = require("packui.lock").get_commit(p.name)
      if target_commit then
        table.insert(queue, function(done)
          state.update_status(p.name, "updating")
          if package.loaded["packui.ui"] then require("packui.ui").update() end

          M.spawn(p, "git", { "fetch", "origin", target_commit }, p.dir, function()
            M.spawn(p, "git", { "checkout", target_commit }, p.dir, function(code)
              if code == 0 then
                state.update_status(p.name, "installed")
                state.set_behind(p.name, 0)
                state.set_outdated_detail(p.name, {})
              else
                state.update_status(p.name, "error")
              end
              done()
              if package.loaded["packui.ui"] then require("packui.ui").update() end
            end)
          end)
        end)
      end
    end
  end
  process_queue()
end

return M
