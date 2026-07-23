local state = require("packui.state")
local ui = require("packui.ui")
local loader = require("packui.loader")

local M = {}

M.config = {
  install_path = vim.fn.stdpath("data") .. "/site/pack/packui",
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

function M.setup(opts)
  if opts and opts.plugins then
    opts.plugins = load_plugins(opts.plugins)
  end
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  state.init(M.config)
  loader.init(M.config)
  
  -- create commands
  vim.api.nvim_create_user_command("Packui", function()
    ui.open(M.config)
  end, {})
  
  vim.api.nvim_create_user_command("PackuiSync", function()
    require("packui.async").sync(M.config)
  end, {})
end

return M
