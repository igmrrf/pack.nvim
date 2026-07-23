local persist = require("packui.persist")

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
  }
end

function M.init(config)
  M.plugins = {}
  local disabled_set = persist.load()
  for _, p in ipairs(config.plugins) do
    local normalized = normalize(p)
    if not normalized then
      vim.notify("packui: skipping invalid plugin spec (missing url): " .. vim.inspect(p), vim.log.levels.WARN)
      goto continue
    end
    normalized.disabled = disabled_set[normalized.name] or false
    -- Everything lives under opt/ and is packadd'd explicitly (lazily on
    -- trigger, or immediately in loader.init() for non-lazy plugins).
    -- :packadd only resolves pack/*/opt/{name} - a start/ package is only
    -- auto-loaded by Nvim's own startup scan, which runs before install_path
    -- is ever added to 'packpath', so start/ plugins installed or configured
    -- through packui would silently never load.
    normalized.dir = config.install_path .. "/opt/" .. normalized.name
    local legacy_start_dir = config.install_path .. "/start/" .. normalized.name

    if vim.fn.isdirectory(normalized.dir) == 0 and vim.fn.isdirectory(legacy_start_dir) == 1 then
      local parent_dir = vim.fn.fnamemodify(normalized.dir, ":h")
      vim.fn.mkdir(parent_dir, "p")
      vim.fn.rename(legacy_start_dir, normalized.dir)
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
