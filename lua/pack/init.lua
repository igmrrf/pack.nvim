local state = require("pack.state")
local ui = require("pack.ui")
local loader = require("pack.loader")

local M = {}

M.config = {
  -- Install location and lockfile are owned by native vim.pack and are not
  -- configurable; kept here for reference/back-compat only.
  install_path = vim.fn.stdpath("data") .. "/site/pack/core/opt",
  lockfile_path = vim.fn.stdpath("config") .. "/nvim-pack-lock.json",
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
      specs[#specs + 1] = state.to_native_spec(p)
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
        specs_to_add[#specs_to_add + 1] = state.to_native_spec(p)
      end
    end
    M._install_and_load(specs_to_add, false)
  end
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
    pcall(function() M.native_pack.del(names) end)
  end
  vim.pack.update = function(names)
    M.native_pack.update(names)
  end

  -- create commands
  vim.api.nvim_create_user_command("Pack", function(opts)
    local args_list = {}
    for word in opts.args:gmatch("%S+") do table.insert(args_list, word) end
    local subcmd = args_list[1]
    local target = args_list[2]

    if subcmd == "sync" then
      M.native_pack.update()
    elseif subcmd == "update" then
      if target then
        if state.get_plugins()[target] then
          M.native_pack.update({ target })
        else
          vim.notify("pack: Plugin not found: " .. target, vim.log.levels.ERROR)
        end
      else
        M.native_pack.update()
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
      local managed = M.native_pack.get and M.native_pack.get() or {}
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
      M.native_pack.update(nil, { target = "lockfile" })
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
