local state = require("pack.state")
local ui = require("pack.ui")
local loader = require("pack.loader")

local M = {}

M.config = {
  install_path = vim.fn.stdpath("data") .. "/site/pack/pack",
  lockfile_path = vim.fn.stdpath("config") .. "/nvim-pack-lock.json",
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
  if type(spec) == "table" then return spec end
  if type(spec) ~= "string" then return {} end
  
  local plugins = {}
  local path = spec:gsub("%.", "/")
  local files = vim.api.nvim_get_runtime_file("lua/" .. path .. "/**/*.lua", true)
  
  if #files == 0 then
    -- Try loading it as a single module
    local ok, mod = pcall(require, spec)
    return (ok and type(mod) == "table") and mod or {}
  end

  for _, file in ipairs(files) do
    -- Convert path back to module name
    local mod_path = file:match("lua/(.*)%.lua$")
    if mod_path then
      local mod_name = mod_path:gsub("/", ".")
      local ok, mod = pcall(require, mod_name)
      if ok and type(mod) == "table" then
        if type(mod[1]) == "table" or #mod > 1 then
          -- It's a list of plugins
          for _, p in ipairs(mod) do
            table.insert(plugins, p)
          end
        elseif mod[1] and type(mod[1]) == "string" then
          -- It's a single plugin spec
          table.insert(plugins, mod)
        end
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

function M.setup(opts)
  local plugins
  if opts and opts.plugins then
    plugins = load_plugins(opts.plugins)
    opts.plugins = nil
  end
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  M.config.plugins = plugins or M.config.plugins
  state.init(M.config)
  loader.init(M.config)
  require("pack.lock").init(M.config)
  
  -- Drop-in replacement for vim.pack
  vim.pack = vim.pack or {}
  vim.pack.add = function(specs)
    local items = specs
    if type(specs) == "string" then
      items = { specs }
    elseif type(specs) == "table" and not specs[1] and specs.src then
      items = { specs }
    end

    local added_plugins = {}
    for _, item in ipairs(items) do
      local p = item
      if type(item) == "string" then
        p = { item }
      elseif type(item) == "table" then
        if item.src then
          p = { item.src, as = item.name }
        end
      end
      
      local newly_added = state.add_plugin(p, M.config)
      if newly_added and #newly_added > 0 then
        for _, ap in ipairs(newly_added) do
          table.insert(added_plugins, ap)
        end
      end
    end
    
    if #added_plugins > 0 then
      require("pack.lock").init(M.config)
      for _, p in ipairs(added_plugins) do
        if not p.disabled and p.status == "installed" then
          loader.enable(p)
        end
      end
    end
  end

  vim.pack.del = function(names)
    if type(names) == "string" then names = { names } end
    for _, name in ipairs(names) do
      if state.get_plugins()[name] then
        state.get_plugins()[name] = nil
      end
    end
  end

  vim.pack.update = function()
    require("pack.async").sync(M.config)
  end
  
  -- create commands
  vim.api.nvim_create_user_command("Pack", function(opts)
    local arg = opts.args
    if arg == "sync" then
      require("pack.async").sync(M.config)
    elseif arg == "restore" then
      require("pack.async").restore()
    elseif arg == "profile" then
      local plugins = state.get_plugins()
      local profiles = {}
      for _, p in pairs(plugins) do
        if p.load_time then
          table.insert(profiles, p)
        end
      end
      table.sort(profiles, function(a, b) return a.load_time > b.load_time end)
      
      local lines = { "  Pack Startup Profile", "  ====================" }
      for _, p in ipairs(profiles) do
        table.insert(lines, string.format("  %8.2f ms  %s", p.load_time, p.name))
      end
      
      if #profiles == 0 then table.insert(lines, "  No profiles recorded.") end
      
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].bufhidden = "wipe"
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.api.nvim_command("split")
      vim.api.nvim_win_set_buf(0, buf)
    else
      ui.open(M.config)
    end
  end, {
    nargs = "?",
    complete = function(ArgLead, CmdLine, CursorPos)
      local subcommands = { "sync", "restore", "profile" }
      local matches = {}
      for _, cmd in ipairs(subcommands) do
        if cmd:find("^" .. vim.pesc(ArgLead)) then
          table.insert(matches, cmd)
        end
      end
      return matches
    end
  })
end

return M
