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
        state.update_status(plugin.name, "installed")
        
        -- Automatically load the plugin if it's not lazy-loaded
        if not plugin.lazy then
          vim.schedule(function()
            require("packui.loader").load(plugin.name)
          end)
        end
      else
        state.update_status(plugin.name, "error")
      end
      done()
      if package.loaded["packui.ui"] then
        require("packui.ui").update()
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
        state.update_status(plugin.name, was_loaded and "loaded" or "installed")
      else
        state.update_status(plugin.name, "error")
      end
      done()
      if package.loaded["packui.ui"] then
        require("packui.ui").update()
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
        if count_code == 0 then
          local behind = M.parse_behind_count(output)
          if behind then
            state.set_behind(plugin.name, behind)
            if package.loaded["packui.ui"] then
              require("packui.ui").update()
            end
          end
        end
        done()
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
    if p.status == "installing" or p.status == "updating" then
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

return M
