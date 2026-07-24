local state = require("pack.state")
local ui = require("pack.ui")
local loader = require("pack.loader")

local M = {}

M.config = {
  -- Install location and lockfile are owned by native vim.pack and are not
  -- configurable, so they are intentionally not part of this config table.
  performance = {
    vim_loader = true,
  },
  plugins = {},
  ui = {
    border = "rounded",
    icons = {
      loaded = "●",
      not_loaded = "○",
      error = "✖",
      sync = "↺"
    }
  }
}

local function load_plugins(spec)
  if type(spec) == "table" then
    if spec.import then
      return load_plugins(spec.import)
    end
    -- Distinguish ONE plugin spec from a LIST of specs (lazy.nvim's rule): it is
    -- a list only if it has more than one positional entry or a table at [1].
    -- Otherwise a table carrying a url ([1] string or src=) is a single spec and
    -- must be returned wrapped -- iterating it would keep only the bare url and
    -- silently drop opts/config/keys/lazy/etc.
    if not (#spec > 1 or type(spec[1]) == "table") then
      if spec[1] or spec.src then
        return { spec }
      end
      return {}
    end
    local plugins = {}
    for _, item in ipairs(spec) do
      if type(item) == "table" and item.import then
        local imported = load_plugins(item.import)
        for _, p in ipairs(imported) do table.insert(plugins, p) end
      else
        table.insert(plugins, item)
      end
    end
    return plugins
  end

  if type(spec) ~= "string" then return {} end
  
  local plugins = {}
  local path = spec:gsub("%.", "/")
  local files = vim.api.nvim_get_runtime_file("lua/" .. path .. "/**/*.lua", true)
  
  if #files == 0 then
    local ok, mod = pcall(require, spec)
    if ok and type(mod) == "table" then
      return load_plugins(mod)
    end
    return plugins
  end

  for _, file in ipairs(files) do
    local mod_path = file:match("lua/(.*)%.lua$")
    if mod_path then
      local mod_name = mod_path:gsub("/", ".")
      local ok, mod = pcall(require, mod_name)
      if ok and type(mod) == "table" then
        local sub = load_plugins(mod)
        for _, p in ipairs(sub) do table.insert(plugins, p) end
      end
    end
  end
  return plugins
end

-- Exposed for tests: normalize a user `plugins`/`import` value into a flat spec
-- list without registering anything.
M._load_plugins = load_plugins

-- Bulk-register keymaps: { { lhs, rhs, mode = "n"|{...}, desc = "...", ... }, ... }
function M.map_keys(keys)
  for _, k in ipairs(keys) do
    local mode = k.mode or "n"
    local opts = {}
    for key, value in pairs(k) do
      if type(key) == "string" and key ~= "mode" then
        opts[key] = value
      end
    end
    vim.keymap.set(mode, k[1], k[2], opts)
  end
end

-- Build native vim.pack specs for every non-disabled plugin in a state map.
local function collect_native_specs(plugins_map)
  local specs = {}
  for _, p in pairs(plugins_map) do
    if not p.disabled then
      local ns = state.to_native_spec(p)
      if ns then
        specs[#specs + 1] = ns
      end
    end
  end
  return specs
end

-- Hand a batch of native specs to native vim.pack (which clones/checks out and
-- calls loader.load_fn per plugin instead of sourcing), then run our ordered
-- loader. Native never touches runtimepath - we own all loading.
function M._install_and_load(native_specs, confirm)
  if M.native_pack and M.native_pack.add and #native_specs > 0 then
    M.native_pack.add(native_specs, { load = loader.load_fn, confirm = confirm })
  end
  -- Local (dir=) plugins never reach native; enqueue them for the same ordered
  -- load pass so they load at startup like everything else.
  loader.queue_local_plugins()
  loader.flush_pending()
end

-- Public add: accepts pack.nvim shorthand ({ "u/r", lazy=true }) or native-style
-- specs ({ src=..., name=..., version=... }), registers them in state, and
-- installs+loads any newly-added, non-disabled plugins via native vim.pack.
function M.add(specs)
  local items = specs
  if type(specs) == "string" then
    items = { specs }
  elseif type(specs) == "table" and not specs[1] and specs.src then
    items = { specs }
  end

  local added = {}
  for _, item in ipairs(items) do
    local raw = item
    if type(item) == "string" then
      raw = { item }
    end
    -- Native-style ({ src=..., name=..., lazy=..., opts=... }) and shorthand
    -- ({ "owner/repo", lazy=..., opts=... }) both pass through untouched;
    -- normalize() reads url from [1] or src and keeps all pack.nvim fields.
    local newly = state.add_plugin(raw, M.config)
    for _, ap in ipairs(newly) do
      added[#added + 1] = ap
    end
  end

  if #added > 0 then
    local specs_to_add = {}
    for _, p in ipairs(added) do
      if not p.disabled then
        local ns = state.to_native_spec(p)
        if ns then
          specs_to_add[#specs_to_add + 1] = ns
        end
      end
    end
    M._install_and_load(specs_to_add, false)
  end
end

-- pcall wrapper for native vim.pack calls. Its API is still evolving in Neovim
-- nightly, so a signature/option change (e.g. update's `target`/`force`) would
-- otherwise throw straight out of a :Pack command with no user-facing message.
local function native_call(desc, fn, ...)
  if type(fn) ~= "function" then
    vim.notify("pack: native vim.pack." .. desc .. " is unavailable", vim.log.levels.ERROR)
    return false
  end
  local ok, err = pcall(fn, ...)
  if not ok then
    vim.notify("pack: " .. desc .. " failed: " .. tostring(err), vim.log.levels.ERROR)
  end
  return ok
end

function M.setup(opts)
  local plugins
  if opts and opts.plugins then
    plugins = load_plugins(opts.plugins)
    opts.plugins = nil
  end
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  if M.config.performance and M.config.performance.vim_loader and vim.loader then
    vim.loader.enable()
  end
  M.config.plugins = plugins or M.config.plugins

  -- Delegate all git operations to Neovim 0.12+ native vim.pack (preserved on
  -- M.native_pack). pack.nvim layers lazy-loading, config/opts, build hooks and
  -- the dashboard on top; native owns clone/checkout/update/lockfile/pinning.
  M.native_pack = vim.pack
  if not (M.native_pack and M.native_pack.add) then
    vim.notify("pack.nvim requires Neovim 0.12+ (native vim.pack)", vim.log.levels.ERROR)
    return
  end

  state.init(M.config)
  loader.init(M.config)

  -- Register build hooks BEFORE installing so PackChanged(install) events from
  -- the initial add() are caught.
  require("pack.async").setup_build_hooks()

  -- Install (native) + load (ours) every configured plugin. confirm=false so
  -- startup installs run silently rather than prompting.
  M._install_and_load(collect_native_specs(state.get_plugins()), false)

  -- Lazy-aware wrapper. Unoverridden methods (get, ...) fall through to native.
  vim.pack = setmetatable({}, { __index = M.native_pack })
  vim.pack.add = function(specs)
    M.add(specs)
  end
  vim.pack.del = function(names)
    if type(names) == "string" then names = { names } end
    for _, name in ipairs(names) do
      local p = state.get_plugins()[name]
      if p then
        -- Tear down lazy triggers (autocmds/commands/keymaps) before dropping,
        -- otherwise they leak and fire against a plugin that no longer exists.
        pcall(function() loader.remove_triggers(p) end)
        state.remove_plugin(name)
      end
    end
    -- Native removes the dir + lockfile entry.
    native_call("del", M.native_pack.del, names)
  end
  vim.pack.update = function(names, update_opts)
    -- Forward native's second arg (force/target/...) instead of dropping it, and
    -- guard against a native API mismatch.
    native_call("update", M.native_pack.update, names, update_opts)
  end

  -- create commands
  vim.api.nvim_create_user_command("Pack", function(opts)
    local args_list = {}
    for word in opts.args:gmatch("%S+") do table.insert(args_list, word) end
    local subcmd = args_list[1]
    local target = args_list[2]

    if subcmd == "sync" then
      native_call("sync", M.native_pack.update)
    elseif subcmd == "update" then
      if target then
        if state.get_plugins()[target] then
          native_call("update", M.native_pack.update, { target })
        else
          vim.notify("pack: Plugin not found: " .. target, vim.log.levels.ERROR)
        end
      else
        native_call("update", M.native_pack.update)
      end
    elseif subcmd == "build" then
      if target then
        local p = state.get_plugins()[target]
        if p then
          require("pack.async").run_build_hook(p, function() vim.notify("pack: Built " .. target) end)
        else
          vim.notify("pack: Plugin not found: " .. target, vim.log.levels.ERROR)
        end
      else
        for _, p in pairs(state.get_plugins()) do
          require("pack.async").run_build_hook(p, function() end)
        end
        vim.notify("pack: Triggered builds")
      end
    elseif subcmd == "load" then
      if target then
        require("pack.loader").load(target)
        vim.notify("pack: Loaded " .. target)
      end
    elseif subcmd == "delete" then
      if target then
        vim.pack.del({ target })
        vim.notify("pack: Deleted " .. target)
      end
    elseif subcmd == "clean" then
      -- Remove plugins native still manages (on disk / in lockfile) that are no
      -- longer in the configured spec.
      local ok_get, managed = pcall(function()
        return M.native_pack.get and M.native_pack.get() or {}
      end)
      if not ok_get then
        managed = {}
      end
      local configured = state.get_plugins()
      local removed = 0
      for _, entry in ipairs(managed) do
        local name = entry.spec and entry.spec.name
        if name and not configured[name] then
          pcall(function() M.native_pack.del({ name }) end)
          vim.notify("pack: Removed unused plugin " .. name)
          removed = removed + 1
        end
      end
      if removed == 0 then
        vim.notify("pack: Already clean")
      end
    elseif subcmd == "restore" then
      native_call("restore", M.native_pack.update, nil, { target = "lockfile" })
    elseif subcmd == "profile" then
      ui.open(M.config)
      ui.show_profile()
    else
      ui.open(M.config)
    end
  end, {
    nargs = "*",
    complete = function(ArgLead, CmdLine, CursorPos)
      local args = {}
      for word in CmdLine:sub(1, CursorPos):gmatch("%S+") do table.insert(args, word) end
      if CmdLine:sub(CursorPos, CursorPos):match("%s") then table.insert(args, "") end

      if #args <= 2 then
        local subcommands = { "sync", "clean", "restore", "profile", "update", "build", "load", "delete" }
        local matches = {}
        for _, cmd in ipairs(subcommands) do
          if cmd:find("^" .. vim.pesc(ArgLead)) then
            table.insert(matches, cmd)
          end
        end
        return matches
      elseif #args == 3 then
        local subcmd = args[2]
        if subcmd == "update" or subcmd == "build" or subcmd == "load" or subcmd == "delete" then
          local matches = {}
          for name, _ in pairs(state.get_plugins()) do
            if name:find("^" .. vim.pesc(ArgLead)) then
              table.insert(matches, name)
            end
          end
          return matches
        end
      end
      return {}
    end
  })
end

return M
