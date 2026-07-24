local state = require("pack.state")
local ui = require("pack.ui")
local loader = require("pack.loader")

local M = {}

M.config = {
  install_path = vim.fn.stdpath("data") .. "/site/pack/pack",
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
    local args_list = {}
    for word in opts.args:gmatch("%S+") do table.insert(args_list, word) end
    local subcmd = args_list[1]
    local target = args_list[2]

    if subcmd == "sync" then
      require("pack.async").sync(M.config)
    elseif subcmd == "update" then
      if target then
        local p = state.get_plugins()[target]
        if p then
          require("pack.async").update_plugin(p)
          vim.notify("pack: Updating " .. target)
        else
          vim.notify("pack: Plugin not found: " .. target, vim.log.levels.ERROR)
        end
      else
        require("pack.async").sync(M.config)
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
        local p = state.get_plugins()[target]
        if p and p.dir then
          vim.fn.delete(p.dir, "rf")
          state.get_plugins()[target] = nil
          vim.notify("pack: Deleted " .. target)
        end
      end
    elseif subcmd == "clean" then
      local install_dir = M.config.install_path .. "/opt"
      local handle = vim.uv.fs_scandir(install_dir)
      if handle then
        local active_dirs = {}
        for _, p in pairs(state.get_plugins()) do
          if p.dir then active_dirs[p.dir] = true end
        end
        local to_remove = {}
        while true do
          local name, typ = vim.uv.fs_scandir_next(handle)
          if not name then break end
          local full_path = install_dir .. "/" .. name
          if not active_dirs[full_path] then
            table.insert(to_remove, full_path)
          end
        end
        if #to_remove > 0 then
          for _, path in ipairs(to_remove) do
            vim.fn.delete(path, "rf")
            vim.notify("pack: Removed unused plugin " .. vim.fn.fnamemodify(path, ":t"))
          end
        else
          vim.notify("pack: Already clean")
        end
      end
    elseif subcmd == "restore" then
      require("pack.async").restore()
    elseif subcmd == "profile" then
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
