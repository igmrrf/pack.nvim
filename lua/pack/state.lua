local persist = require("pack.persist")

local M = {}

M.plugins = {}

-- Derive the require() module name from a plugin name when `main` isn't set,
-- following the common "<module>.nvim" repo naming convention.
local function default_main(name)
  return name:match("^(.+)%.nvim$") or name
end

-- normalize the plugin definition
local function normalize(plugin)
  if type(plugin) == "string" then
    plugin = { plugin }
  end

  local enabled = plugin.enabled
  if type(enabled) == "function" then enabled = enabled() end
  if enabled == false then return nil end

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
  
  local config = plugin.config
  if not config and plugin.opts then
    local main = plugin.main or default_main(name)
    config = function()
      require(main).setup(plugin.opts)
    end
  end

  local dependencies = plugin.dependencies or {}
  if type(dependencies) == "string" then dependencies = { dependencies } end

  local build = plugin.build

  return {
    url = full_url,
    name = name,
    lazy = plugin.lazy or false,
    cmd = plugin.cmd,
    event = plugin.event,
    ft = plugin.ft,
    keys = plugin.keys,
    main = plugin.main,
    opts = plugin.opts,
    config = config,
    init_hook = plugin.init,
    cond = plugin.cond,
    priority = plugin.priority or 50,
    dir = "",
    status = "unknown", -- missing, installed, loaded, error
    log = {},
    disabled = false,
    behind = nil,
    checked_at = nil,
    revision_before = nil,
    revision_after = nil,
    upstream_branch = nil,
    pending_commits = nil,
    dependencies = dependencies,
    build = build,
    local_dir = plugin.dir,
  }
end

function M.add_plugin(p, config)
  local normalized = normalize(p)
  if not normalized then
    vim.notify("pack: skipping invalid plugin spec (missing url): " .. vim.inspect(p), vim.log.levels.WARN)
    return {}
  end
  
  if M.plugins[normalized.name] then
    return {}
  end
  
  local disabled_set = persist.load()
  local queue = { p }
  local added_list = {}
  
  while #queue > 0 do
    local curr = table.remove(queue, 1)
    local norm = normalize(curr)
    if not norm then goto continue end
    if M.plugins[norm.name] then goto continue end
    
    for _, dep in ipairs(norm.dependencies) do
      table.insert(queue, dep)
    end
    
    norm.disabled = disabled_set[norm.name] or false
    norm.dir = config.install_path .. "/opt/" .. norm.name
    
    if norm.local_dir then
      norm.local_dir = vim.fn.expand(norm.local_dir)
      if vim.fn.isdirectory(norm.dir) == 0 then
        local parent_dir = vim.fn.fnamemodify(norm.dir, ":h")
        vim.fn.mkdir(parent_dir, "p")
        pcall(vim.uv.fs_symlink, norm.local_dir, norm.dir, { dir = true })
      end
    else
      local legacy_start_dir = config.install_path .. "/start/" .. norm.name
      if vim.fn.isdirectory(norm.dir) == 0 and vim.fn.isdirectory(legacy_start_dir) == 1 then
        local parent_dir = vim.fn.fnamemodify(norm.dir, ":h")
        vim.fn.mkdir(parent_dir, "p")
        vim.fn.rename(legacy_start_dir, norm.dir)
      end
    end
    
    if vim.fn.isdirectory(norm.dir) == 1 then
      norm.status = "installed"
    else
      norm.status = "missing"
    end
    
    M.plugins[norm.name] = norm
    table.insert(added_list, norm)
    ::continue::
  end
  return added_list
end

function M.init(config)
  M.plugins = {}
  for _, p in ipairs(config.plugins) do
    M.add_plugin(p, config)
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

function M.set_disabled(name, disabled)
  if not M.plugins[name] then
    return
  end
  M.plugins[name].disabled = disabled
  persist.set_disabled(name, disabled)
end

function M.set_behind(name, behind)
  if not M.plugins[name] then
    return
  end
  M.plugins[name].behind = behind
  M.plugins[name].checked_at = os.time()
end

function M.set_outdated_detail(name, detail)
  if not M.plugins[name] then
    return
  end
  local p = M.plugins[name]
  p.revision_before = detail.revision_before
  p.revision_after = detail.revision_after
  p.upstream_branch = detail.upstream_branch
  p.pending_commits = detail.pending_commits
end

return M
