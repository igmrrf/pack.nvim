local state = require("pack.state")

local M = {}

-- Generate :help tags for a plugin's doc/ directory so `:help <tag>` works for
-- managed plugins (native vim.pack / :packadd does not do this automatically).
local function gen_helptags(dir)
  if not dir or dir == "" then
    return
  end
  local doc = dir .. "/doc"
  if vim.fn.isdirectory(doc) == 1 and #vim.fn.globpath(doc, "*.txt", true, true) > 0 then
    pcall(vim.cmd, "helptags " .. vim.fn.fnameescape(doc))
  end
end

local function packadd(name)
  local ok, err = pcall(vim.cmd.packadd, name)
  if not ok then
    vim.notify("Error loading plugin " .. name .. ": " .. tostring(err), vim.log.levels.ERROR)
  end
  return ok
end

-- Load a local (`dir=`) plugin. Native vim.pack never manages it and it lives
-- outside the packpath's opt dir, so `:packadd` can't find it: add its directory
-- to 'runtimepath' (for lua/ requires) and source its plugin/ files the way
-- packadd would.
local function load_local(p)
  if not p.dir or p.dir == "" or vim.fn.isdirectory(p.dir) == 0 then
    vim.notify(
      "pack: local plugin directory not found for " .. p.name .. ": " .. tostring(p.dir),
      vim.log.levels.ERROR
    )
    return false
  end
  vim.opt.runtimepath:append(p.dir)
  for _, pat in ipairs({ "plugin/**/*.vim", "plugin/**/*.lua" }) do
    for _, file in ipairs(vim.fn.globpath(p.dir, pat, true, true)) do
      local ok, err = pcall(vim.cmd, "source " .. vim.fn.fnameescape(file))
      if not ok then
        vim.notify("pack: error sourcing " .. file .. ": " .. tostring(err), vim.log.levels.ERROR)
      end
    end
  end
  return true
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
    if not lhs then
      vim.notify(
        "pack: '" .. p.name .. "' has a keys entry with no lhs - skipping",
        vim.log.levels.WARN
      )
    elseif not p.lazy then
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
    -- Precompile ftdetect only for LAZY plugins: an eager plugin is sourced at
    -- startup anyway, so its ftdetect runs regardless. A not-yet-loaded lazy
    -- plugin needs this cache for its filetypes to be detected before load.
    -- Accept "loaded" too (a lazy plugin loaded earlier this session).
    if not p.disabled and p.lazy and (p.status == "installed" or p.status == "loaded") then
      local ftdetect_vim = vim.fn.globpath(p.dir, "ftdetect/*.vim", true, true)
      for _, file in ipairs(ftdetect_vim) do
        table.insert(lines, 'vim.cmd("source " .. ' .. string.format("%q", vim.fn.fnameescape(file)) .. ')')
      end
      local ftdetect_lua = vim.fn.globpath(p.dir, "ftdetect/*.lua", true, true)
      for _, file in ipairs(ftdetect_lua) do
        table.insert(lines, 'dofile(' .. string.format("%q", file) .. ')')
      end
    end
  end
  vim.fn.writefile(lines, cache_file)
end

-- modname -> plugin lookup, rebuilt only when state.generation changes so the
-- searcher stays O(1) per require instead of rescanning every plugin each time.
local mod_cache = { gen = -1, map = {} }

local function resolve_plugin(modname)
  if mod_cache.gen ~= state.generation then
    local map = {}
    -- Iterate in a stable (sorted) order so that when two plugins share a base
    -- or head segment, the same one deterministically wins the mapping instead
    -- of depending on pairs() iteration order.
    local plugins = state.get_plugins()
    local names = {}
    for name in pairs(plugins) do
      names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
      local p = plugins[name]
      local base = p.main or (name:match("([^/]+)$") or name):gsub("%.nvim$", "")
      map[name] = map[name] or p
      map[base] = map[base] or p
      local head = base:match("^([^.]+)")
      if head then map[head] = map[head] or p end
    end
    mod_cache.map = map
    mod_cache.gen = state.generation
  end
  local map = mod_cache.map
  -- Exact module name, or the plugin owning the top-level segment
  -- (require "telescope.builtin" -> plugin with base "telescope").
  return map[modname] or map[modname:match("^([^.]+)")]
end

function M.init(config)
  pcall(dofile, vim.fn.stdpath("data") .. "/pack_ftdetect_cache.lua")

  -- Intercept requires for disabled plugins to prevent configuration crashes.
  -- If a disabled module is required directly (not inside pcall), we return a deep mock table.
  table.insert(package.loaders or package.searchers, 1, function(modname)
    local target_p = resolve_plugin(modname)

    if target_p then
      if target_p.disabled then
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
      elseif target_p.status == "installed" and target_p.lazy and target_p.module ~= false then
        M.load(target_p.name)
        return nil
      end
    end
  end)
  -- Native vim.pack installs plugins under stdpath('data')/site/pack/core/opt,
  -- which is already on 'packpath', so :packadd resolves by name with no
  -- prepending needed. (The old custom installer required packpath munging here.)
end

-- Plugins recorded by load_fn during vim.pack.add, awaiting our ordered load.
local pending = {}

-- Passed to vim.pack.add as its `load` callback. Native invokes this per plugin
-- instead of packadd-ing it (so nothing lands on 'runtimepath' or gets sourced).
-- We only record the plugin + its resolved on-disk path; actual loading happens
-- in flush_pending() after add() returns, so we control order and laziness.
function M.load_fn(data)
  local name = data.spec.name
  local p = state.get_plugins()[name]
  if p then
    p.dir = data.path
    if p.status ~= "loaded" then
      p.status = "installed"
    end
  end
  table.insert(pending, { name = name, path = data.path })
end

-- Enqueue local (`dir=`) plugins for loading. They never pass through native's
-- load_fn (nothing is cloned), so flush_pending would otherwise never see them.
-- Idempotent across calls: a plugin already "loaded" is skipped.
function M.queue_local_plugins()
  for name, p in pairs(state.get_plugins()) do
    if p.is_local and not p.disabled and p.status ~= "loaded" then
      if p.dir and p.dir ~= "" and vim.fn.isdirectory(p.dir) == 1 then
        p.status = "installed"
        table.insert(pending, { name = name, path = p.dir })
      end
    end
  end
end

-- Load everything recorded by load_fn. Eager plugins load first, highest
-- priority first; lazy plugins get their triggers wired instead. `cond` gates
-- both. Mirrors the old startup loop but driven by native's add() callback.
function M.flush_pending()
  local eager = {}
  for _, item in ipairs(pending) do
    local p = state.get_plugins()[item.name]
    if p and not p.disabled and p.status ~= "loaded" then
      local cond_ok = true
      if p.cond ~= nil then
        local cond_val = type(p.cond) == "function" and p.cond({ path = p.dir, spec = p }) or p.cond
        cond_ok = cond_val and true or false
      end
      if cond_ok then
        if p.init_hook then
          pcall(p.init_hook, { path = p.dir, spec = p })
        end
        if p.lazy then
          M.setup_triggers(p)
        else
          table.insert(eager, p)
        end
      end
    end
  end

  table.sort(eager, function(a, b)
    -- Highest priority first; break ties by name so equal-priority plugins load
    -- in a stable order across runs (pairs()/native ordering is nondeterministic).
    if a.priority ~= b.priority then
      return a.priority > b.priority
    end
    return a.name < b.name
  end)

  for _, p in ipairs(eager) do
    -- cond was already evaluated above; don't re-run it (side effects).
    M.load(p.name, { cond_checked = true })
    -- Bind directly-mapped (rhs-bearing) keys for eager plugins; lazy plugins
    -- handle their keys via triggers instead.
    if p.keys and p.status == "loaded" then
      setup_keys(p)
    end
  end

  pending = {}

  -- Regenerate the ftdetect precompile cache now that the installed/lazy set is
  -- settled. pcall so a write failure never breaks startup.
  pcall(M.build_cache)
end

-- Names currently mid-load. Guards the dependency recursion against circular
-- (A->B->A) or diamond specs that would otherwise re-enter an un-"loaded"
-- plugin forever and overflow the stack. Cleared as soon as the deps loop
-- finishes; from there the "loaded" status guard handles re-entry.
local loading = {}

function M.load(name, opts)
  opts = opts or {}
  local plugins = state.get_plugins()
  local p = plugins[name]
  -- "error" plugins already failed to packadd; retrying just re-notifies on
  -- every trigger. A real (re)install resets status to "installed" via load_fn.
  if not p or p.status == "loaded" or p.status == "error" then return end
  -- Never packadd/config a disabled plugin, even when reached as a dependency
  -- or via :Pack load. disabled is otherwise only honored at flush/collect time.
  if p.disabled then return end
  if loading[name] then return end
  loading[name] = true

  if p.dependencies then
    for _, dep in ipairs(p.dependencies) do
      -- Resolve via the same helper registration uses, so a dependency written
      -- native-style ({ src=, name= }) or aliased ({ "o/r", name= }) resolves to
      -- the key it was actually registered under.
      local dep_name = state.derive_name(dep)
      if dep_name then
        M.load(dep_name)
      end
    end
  end

  loading[name] = nil

  if p.cond ~= nil and not opts.cond_checked then
    local cond_val = type(p.cond) == "function" and p.cond({ path = p.dir, spec = p }) or p.cond
    if not cond_val then return end
  end

  -- A lazy plugin can be force-loaded (as another plugin's dependency, or via
  -- :Pack load) while its triggers are still registered; tear them down so a
  -- stale command/keymap/autocmd doesn't fire against an already-loaded plugin.
  if p.lazy then
    pcall(M.remove_triggers, p)
  end

  local start_time = vim.uv.hrtime()
  local loaded_ok = p.is_local and load_local(p) or (not p.is_local and packadd(name))
  if loaded_ok then
    state.update_status(name, "loaded")
    gen_helptags(p.dir)
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
  else
    -- packadd/local-load failed: record it so triggers stop re-attempting.
    state.update_status(name, "error")
  end

  if package.loaded["pack.ui"] then
    require("pack.ui").update()
  end
end

return M
