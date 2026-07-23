local M = {}

M.plugins = {}

-- normalize the plugin definition
local function normalize(plugin)
  if type(plugin) == "string" then
    plugin = { plugin }
  end
  
  local url = plugin[1]
  local match_name = url:match("/([^/]+)$")
  local name = plugin.as or (match_name and match_name or url)
  if name:sub(-4) == ".git" then
    name = name:sub(1, -5)
  end
  
  local full_url = url
  if not (url:match("^https?://") or url:match("^git@")) then
    full_url = "https://github.com/" .. url
  end
  
  return {
    url = full_url,
    name = name,
    lazy = plugin.lazy or false,
    cmd = plugin.cmd,
    event = plugin.event,
    ft = plugin.ft,
    config = plugin.config,
    dir = "",
    status = "unknown", -- missing, installed, loaded, error
    log = {},
  }
end

function M.init(config)
  M.plugins = {}
  for _, p in ipairs(config.plugins) do
    local normalized = normalize(p)
    local path_type = normalized.lazy and "opt" or "start"
    normalized.dir = config.install_path .. "/" .. path_type .. "/" .. normalized.name
    
    if vim.fn.isdirectory(normalized.dir) == 1 then
      normalized.status = "installed"
    else
      normalized.status = "missing"
    end
    
    M.plugins[normalized.name] = normalized
  end
end

function M.get_plugins()
  return M.plugins
end

function M.update_status(name, status)
  if M.plugins[name] then
    M.plugins[name].status = status
  end
end

return M
