local state = require("pack.state")

local M = {}

local function packadd(name)
  local ok, err = pcall(vim.cmd.packadd, name)
  if not ok then
    vim.notify("Error loading plugin " .. name .. ": " .. tostring(err), vim.log.levels.ERROR)
  end
  return ok
end

-- Accepts: "<lhs>" | { "<lhs>", mode=... } | { "<lhs>", rhs, mode=..., desc=..., ... }
local function normalize_key_entries(raw)
  local entries = {}
  local list = type(raw) == "table" and raw or { raw }
  for _, k in ipairs(list) do
    if type(k) == "string" then
      table.insert(entries, { lhs = k, rhs = nil, modes = { "n" }, opts = {} })
    else
      local modes = k.mode or "n"
      modes = type(modes) == "table" and modes or { modes }
      local opts = {}
      for key, value in pairs(k) do
        if type(key) == "string" and key ~= "mode" then
          opts[key] = value
        end
      end
      table.insert(entries, { lhs = k[1] or k.lhs, rhs = k[2], modes = modes, opts = opts })
    end
  end
  return entries
end

-- Entries with an explicit rhs are mapped directly (mirrors pack.map_keys).
-- Bare-lhs entries only make sense on a lazy plugin: pressing the key loads
-- the plugin then replays the keypress so the plugin's own mapping fires.
local function setup_keys(p)
  for _, entry in ipairs(normalize_key_entries(p.keys)) do
    local lhs = entry.lhs
    if not p.lazy then
      if entry.rhs == nil then
        vim.notify(
          "pack: '" .. p.name .. "' keys entry '" .. lhs .. "' has no rhs and the plugin isn't lazy - nothing to bind",
          vim.log.levels.WARN
        )
      else
        for _, mode in ipairs(entry.modes) do
          vim.keymap.set(mode, lhs, entry.rhs, entry.opts)
        end
      end
    else
      local function trigger()
        for _, mode in ipairs(entry.modes) do
          pcall(vim.keymap.del, mode, lhs)
        end
        M.load(p.name)
        local replay = function()
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(lhs, true, true, true), "m", false)
        end
        if entry.rhs == nil then
          -- rely on the plugin's own config() to have (re)defined this mapping
          replay()
        elseif type(entry.rhs) == "function" then
          for _, mode in ipairs(entry.modes) do
            vim.keymap.set(mode, lhs, entry.rhs, entry.opts)
          end
          entry.rhs()
        else
          for _, mode in ipairs(entry.modes) do
            vim.keymap.set(mode, lhs, entry.rhs, entry.opts)
          end
          replay()
        end
      end
      local trigger_opts = vim.tbl_extend("force", { desc = "pack: lazy-load " .. p.name }, entry.opts)
      for _, mode in ipairs(entry.modes) do
        vim.keymap.set(mode, lhs, trigger, trigger_opts)
      end
    end
  end
end

local seen_cmds = {}

function M.setup_triggers(p)
  local group
  if p.event or p.ft then
    group = vim.api.nvim_create_augroup("pack_trigger_" .. p.name, { clear = true })
  end

  if p.cmd then
    local cmds = type(p.cmd) == "table" and p.cmd or { p.cmd }
    for _, cmd in ipairs(cmds) do
      if seen_cmds[cmd] and seen_cmds[cmd] ~= p.name then
        vim.notify(
          "pack: command '" .. cmd .. "' already registered by " .. seen_cmds[cmd] .. ", overwriting for " .. p.name,
          vim.log.levels.WARN
        )
      end
      seen_cmds[cmd] = p.name
      vim.api.nvim_create_user_command(cmd, function(args)
        vim.api.nvim_del_user_command(cmd)
        M.load(p.name)
        local cmd_str = cmd
        if args.args and args.args ~= "" then
          cmd_str = cmd_str .. " " .. args.args
        end
        if args.bang then
          cmd_str = cmd_str .. "!"
        end
        pcall(vim.cmd, cmd_str)
      end, { nargs = "*", bang = true, complete = "file", force = true })
    end
  end

  local ftdetect_vim = vim.fn.globpath(p.dir, "ftdetect/*.vim", true, true)
  local ftdetect_lua = vim.fn.globpath(p.dir, "ftdetect/*.lua", true, true)
  for _, file in ipairs(ftdetect_vim) do
    local ok, err = pcall(vim.cmd, "source " .. vim.fn.fnameescape(file))
    if not ok then
      vim.notify("Error sourcing " .. file .. ": " .. tostring(err), vim.log.levels.ERROR)
    end
  end
  for _, file in ipairs(ftdetect_lua) do
    local ok, err = pcall(vim.cmd, "source " .. vim.fn.fnameescape(file))
    if not ok then
      vim.notify("Error sourcing " .. file .. ": " .. tostring(err), vim.log.levels.ERROR)
    end
  end

  if p.event then
    local events = type(p.event) == "table" and p.event or { p.event }
    for _, event in ipairs(events) do
      local ev_name = event
      local pat = p.pattern
      if type(event) == "table" then
        ev_name = event.event
        pat = event.pattern or pat
      elseif type(event) == "string" and event:find(" ") then
        ev_name, pat = event:match("^(%S+)%s+(.+)$")
      end

      vim.api.nvim_create_autocmd(ev_name, {
        group = group,
        pattern = pat,
        once = true,
        callback = function()
          M.load(p.name)
        end,
      })
    end
  end

  if p.ft then
    local fts = type(p.ft) == "table" and p.ft or { p.ft }
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      pattern = fts,
      once = true,
      callback = function(args)
        M.load(p.name)
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(args.buf) then
            vim.api.nvim_exec_autocmds("FileType", { buffer = args.buf, modeline = false })
          end
        end)
      end,
    })
  end

  if p.keys then
    setup_keys(p)
  end
end

function M.remove_triggers(p)
  pcall(vim.api.nvim_del_augroup_by_name, "pack_trigger_" .. p.name)

  if p.cmd then
    local cmds = type(p.cmd) == "table" and p.cmd or { p.cmd }
    for _, cmd in ipairs(cmds) do
      if seen_cmds[cmd] == p.name then
        pcall(vim.api.nvim_del_user_command, cmd)
        seen_cmds[cmd] = nil
      end
    end
  end

  if p.keys then
    for _, entry in ipairs(normalize_key_entries(p.keys)) do
      for _, mode in ipairs(entry.modes) do
        pcall(vim.keymap.del, mode, entry.lhs)
      end
    end
  end
end

function M.enable(p)
  if p.status == "loaded" then
    return
  end
  if p.lazy then
    M.setup_triggers(p)
  else
    M.load(p.name)
  end
end

function M.build_cache()
  local cache_file = vim.fn.stdpath("data") .. "/pack_ftdetect_cache.lua"
  local plugins = require("pack.state").get_plugins()
  local lines = {}
  for _, p in pairs(plugins) do
    if not p.disabled and p.status == "installed" then
      local ftdetect_vim = vim.fn.globpath(p.dir, "ftdetect/*.vim", true, true)
      for _, file in ipairs(ftdetect_vim) do
        table.insert(lines, 'vim.cmd("source " .. ' .. string.format("q", vim.fn.fnameescape(file)) .. ')')
      end
      local ftdetect_lua = vim.fn.globpath(p.dir, "ftdetect/*.lua", true, true)
      for _, file in ipairs(ftdetect_lua) do
        table.insert(lines, 'dofile(' .. string.format("q", file) .. ')')
      end
    end
  end
  vim.fn.writefile(lines, cache_file)
end

function M.init(config)
  pcall(dofile, vim.fn.stdpath("data") .. "/pack_ftdetect_cache.lua")

  -- Intercept requires for disabled plugins to prevent configuration crashes.
  -- If a disabled module is required directly (not inside pcall), we return a deep mock table.
  table.insert(package.loaders or package.searchers, 1, function(modname)
    local level = 1
    local in_pcall = false
    while true do
      local info = debug.getinfo(level, "fn")
      if not info then break end
      if info.func == pcall or info.func == xpcall then
        in_pcall = true
        break
      end
      level = level + 1
    end

    if in_pcall then return nil end

    local plugins = state.get_plugins()
    local disabled_p = nil
    for name, p in pairs(plugins) do
      if p.disabled then
        local base = name:match("([^/]+)$") or name
        base = base:gsub("%.nvim$", "")
        if modname == name or modname == base or modname:match("^" .. vim.pesc(base) .. "%.") then
          disabled_p = p
          break
        end
      end
    end

    if disabled_p then
      return function()
        local function make_mock()
          local mock = {}
          setmetatable(mock, {
            __index = function() return make_mock() end,
            __call = function() return make_mock() end,
          })
          return mock
        end
        return make_mock()
      end
    end
  end)
  -- :packadd resolves <packpath-entry>/pack/*/opt|start/<name>, and our plugin
  -- dirs live at install_path/opt|start/<name>, so the packpath entry must be
  -- install_path's grandparent (install_path itself must end in "pack/<name>").
  local packpath_root = vim.fn.fnamemodify(config.install_path, ":h:h")
  if vim.fn.fnamemodify(config.install_path, ":h:t") ~= "pack" then
    vim.notify(
      "pack: install_path '" .. config.install_path .. "' should end in 'pack/<name>' for :packadd to find plugins",
      vim.log.levels.WARN
    )
  end
  vim.opt.packpath:prepend(packpath_root)

  local plugins = state.get_plugins()
  local plugins_list = {}
  for _, p in pairs(plugins) do
    table.insert(plugins_list, p)
  end
  table.sort(plugins_list, function(a, b)
    return a.priority > b.priority
  end)

  for _, p in ipairs(plugins_list) do
    if not p.disabled and p.status == "installed" then
      local skip = false
      if p.cond ~= nil then
        local cond_val = type(p.cond) == "function" and p.cond({ path = p.dir, spec = p }) or p.cond
        if not cond_val then skip = true end
      end

      if not skip then
        if p.init_hook then
          pcall(p.init_hook, { path = p.dir, spec = p })
        end

        if p.lazy then
          M.setup_triggers(p)
        else
          local start_time = vim.uv.hrtime()
          if packadd(p.name) then
            state.update_status(p.name, "loaded")
            local elapsed = (vim.uv.hrtime() - start_time) / 1e6
            if p.config then
              vim.schedule(function()
                local config_start = vim.uv.hrtime()
                local ok, err = pcall(p.config, { path = p.dir, spec = p }, p.opts)
                p.load_time = elapsed + (vim.uv.hrtime() - config_start) / 1e6
                if not ok then
                  vim.notify("Error loading config for " .. p.name .. ": " .. tostring(err), vim.log.levels.ERROR)
                end
              end)
            else
              p.load_time = elapsed
            end
          end

          if p.keys and p.status == "loaded" then
            setup_keys(p)
          end
        end
      end
    end
  end
end

function M.load(name)
  local plugins = state.get_plugins()
  local p = plugins[name]
  if not p or p.status == "loaded" then return end

  if p.dependencies then
    for _, dep in ipairs(p.dependencies) do
      local dep_name
      if type(dep) == "string" then
        local match_name = dep:match("/([^/]+)$")
        dep_name = match_name and match_name or dep
        if dep_name:sub(-4) == ".git" then dep_name = dep_name:sub(1, -5) end
      else
        local match_name = dep[1] and dep[1]:match("/([^/]+)$")
        dep_name = dep.as or (match_name and match_name or dep[1])
        if dep_name and dep_name:sub(-4) == ".git" then dep_name = dep_name:sub(1, -5) end
      end
      if dep_name then
        M.load(dep_name)
      end
    end
  end

  if p.cond ~= nil then
    local cond_val = type(p.cond) == "function" and p.cond({ path = p.dir, spec = p }) or p.cond
    if not cond_val then return end
  end

  local start_time = vim.uv.hrtime()
  if packadd(name) then
    state.update_status(name, "loaded")
    local elapsed = (vim.uv.hrtime() - start_time) / 1e6

    if p.config then
      local config_start = vim.uv.hrtime()
      local ok, err = pcall(p.config, { path = p.dir, spec = p }, p.opts)
      p.load_time = elapsed + (vim.uv.hrtime() - config_start) / 1e6
      if not ok then
        vim.notify("Error loading config for " .. name .. ": " .. tostring(err), vim.log.levels.ERROR)
      end
    else
      p.load_time = elapsed
    end
  end

  if package.loaded["pack.ui"] then
    require("pack.ui").update()
  end
end

return M
