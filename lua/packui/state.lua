local M = {}

M.plugins = {}

-- normalize the plugin definition
local function normalize(plugin)
  if type(plugin) == "string" then
    plugin = { plugin }
  end

  local url = plugin[1]
  if type(url) ~= "string" or url == "" then
    return nil
  end

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
    if not normalized then
      vim.notify("packui: skipping invalid plugin spec (missing url): " .. vim.inspect(p), vim.log.levels.WARN)
      goto continue
    end
    local path_type = normalized.lazy and "opt" or "start"
    local other_path_type = normalized.lazy and "start" or "opt"
    normalized.dir = config.install_path .. "/" .. path_type .. "/" .. normalized.name
    local other_dir = config.install_path .. "/" .. other_path_type .. "/" .. normalized.name
    
    if vim.fn.isdirectory(normalized.dir) == 0 and vim.fn.isdirectory(other_dir) == 1 then
      local parent_dir = vim.fn.fnamemodify(normalized.dir, ":h")
      vim.fn.mkdir(parent_dir, "p")
      vim.fn.rename(other_dir, normalized.dir)
    end
    
    if vim.fn.isdirectory(normalized.dir) == 1 then
      normalized.status = "installed"
    else
      normalized.status = "missing"
    end
    
    M.plugins[normalized.name] = normalized
    ::continue::
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
