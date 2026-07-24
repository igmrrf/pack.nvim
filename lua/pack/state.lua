local persist = require("pack.persist")

local M = {}

M.plugins = {}

-- Bumped whenever the set of registered plugins changes (add/remove). Consumers
-- that cache derived views (e.g. loader's module->plugin map) compare against
-- this to know when to rebuild instead of rescanning on every lookup.
M.generation = 0

-- Directory native vim.pack installs plugins into (fixed, not configurable):
-- stdpath('data')/site/pack/core/opt.
function M.native_opt_dir()
  return vim.fs.joinpath(vim.fn.stdpath("data"), "site", "pack", "core", "opt")
end

-- Derive the require() module name from a plugin name when `main` isn't set,
-- following the common "<module>.nvim" repo naming convention.
local function default_main(name)
  return name:match("^(.+)%.nvim$") or name
end

-- Reject git refs that would be parsed as options (leading dash), e.g. a
-- poisoned spec/lockfile value like "--upload-pack=...". These flow straight
-- into `git` argv, so a ref starting with "-" is never legitimate.
local function safe_ref(value, field, name)
  if type(value) == "string" and value:find("^%-") then
    vim.notify(
      ("pack: ignoring %s '%s' for '%s' (leading dash not allowed)"):format(field, value, name),
      vim.log.levels.WARN
    )
    return nil
  end
  return value
end

-- normalize the plugin definition
local function normalize(plugin, config)
  if type(plugin) == "string" then
    plugin = { plugin }
  end

  local enabled = plugin.enabled
  if type(enabled) == "function" then enabled = enabled() end
  if enabled == false then return nil end

  -- Accept both pack.nvim shorthand (url at [1]) and native vim.pack.Spec style
  -- (`src=`). Handling it here means dependencies written either way normalize
  -- too, and `src=` specs keep every pack.nvim field (lazy/event/opts/...).
  local url = plugin[1] or plugin.src
  if type(url) ~= "string" or url == "" then
    return nil
  end

  local match_name = url:match("/([^/]+)$")
  local name = plugin.as or plugin.name or (match_name and match_name or url)
  if name:sub(-4) == ".git" then
    name = name:sub(1, -5)
  end
  
  -- Treat full URLs, scp-style git remotes, file:// URLs, and absolute/home
  -- local paths as-is; only bare "owner/repo" shorthand expands to GitHub.
  local full_url = url
  if url:match("^~") then
    full_url = vim.fn.expand(url)
  elseif not (url:match("^%w[%w+.-]*://") or url:match("^git@") or url:match("^/")) then
    full_url = "https://github.com/" .. url
  end
  
  local config_fn = plugin.config
  if not config_fn and plugin.opts then
    local main = plugin.main or default_main(name)
    config_fn = function()
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
    pattern = plugin.pattern,
    main = plugin.main,
    opts = plugin.opts,
    config = config_fn,
    init_hook = plugin.init,
    cond = plugin.cond,
    priority = plugin.priority or 50,
    branch = safe_ref(plugin.branch, "branch", name),
    tag = safe_ref(plugin.tag, "tag", name),
    commit = safe_ref(plugin.commit, "commit", name),
    version = plugin.version,
    sem_version = plugin.sem_version,
    module = plugin.module,
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
  local normalized = normalize(p, config)
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
    local norm = normalize(curr, config)
    if not norm then goto continue end
    if M.plugins[norm.name] then goto continue end
    
    for _, dep in ipairs(norm.dependencies) do
      table.insert(queue, dep)
    end
    
    norm.disabled = disabled_set[norm.name] or false
    -- Native vim.pack owns the install location; this is the authoritative path
    -- it will use. load_fn / reconcile_from_native confirm it post-install, but
    -- computing it here lets us show an accurate status before add() runs.
    norm.dir = M.native_opt_dir() .. "/" .. norm.name

    if vim.fn.isdirectory(norm.dir) == 1 then
      norm.status = "installed"
    else
      norm.status = "missing"
    end

    M.plugins[norm.name] = norm
    table.insert(added_list, norm)
    ::continue::
  end
  if #added_list > 0 then
    M.generation = M.generation + 1
  end
  return added_list
end

function M.remove_plugin(name)
  if M.plugins[name] then
    M.plugins[name] = nil
    M.generation = M.generation + 1
    return true
  end
  return false
end

function M.init(config)
  M.plugins = {}
  M.generation = M.generation + 1
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

-- Refresh installed-status / on-disk path / recorded revision from what native
-- vim.pack actually has. load_fn already reconciles on add; this is for the
-- dashboard to reflect installs/updates that happened via native afterwards.
function M.reconcile_from_native(native_pack)
  if not (native_pack and native_pack.get) then
    return
  end
  local ok, list = pcall(native_pack.get)
  if not ok or type(list) ~= "table" then
    return
  end

  -- A plugin native itself packadd-ed (e.g. pack.nvim bootstrapped via
  -- vim.pack.add before setup) is already active on 'runtimepath' but never
  -- went through our load_fn -- native's pack_add returns early for plugins
  -- already in its active set, so our loader never marks it "loaded". Detect
  -- that via runtimepath membership so the dashboard reports it correctly.
  local rtp = {}
  for _, path in ipairs(vim.api.nvim_list_runtime_paths()) do
    rtp[vim.fs.normalize(path)] = true
  end

  for _, entry in ipairs(list) do
    local name = entry.spec and entry.spec.name
    local p = name and M.plugins[name]
    if p then
      p.dir = entry.path or p.dir
      p.rev = entry.rev or p.rev
      if p.status == "missing" then
        p.status = "installed"
      end
      if p.status == "installed" and p.dir and rtp[vim.fs.normalize(p.dir)] then
        p.status = "loaded"
      end
    end
  end
end

-- Resolve a pack.nvim plugin's pin fields to native vim.pack's single
-- `version`. Precedence: commit > tag > branch > version/sem_version range.
-- A range string ("^1.0", ">=0.5") becomes a vim.version range object; a plain
-- ref (branch/tag/sha) is passed through as a string, which native accepts.
local function resolve_version(p)
  if p.commit then return p.commit end
  if p.tag then return p.tag end
  if p.branch then return p.branch end
  local range_str = p.version or p.sem_version
  if range_str == nil then return nil end
  if type(range_str) == "table" then
    return range_str
  end
  local ok, range = pcall(vim.version.range, range_str)
  if ok then return range end
  vim.notify(
    ("pack: '%s' has an invalid version range '%s', ignoring"):format(p.name, tostring(range_str)),
    vim.log.levels.WARN
  )
  return nil
end

-- Translate an internal normalized plugin into a native vim.pack spec. All the
-- lazy-loading / config metadata native has no concept of is stashed under
-- `data`, which round-trips through vim.pack.get() and PackChanged payloads
-- (functions survive vim.deepcopy by reference).
function M.to_native_spec(p)
  return {
    src = p.url,
    name = p.name,
    version = resolve_version(p),
    data = {
      lazy = p.lazy,
      event = p.event,
      ft = p.ft,
      cmd = p.cmd,
      keys = p.keys,
      pattern = p.pattern,
      config = p.config,
      opts = p.opts,
      build = p.build,
      init = p.init_hook,
      cond = p.cond,
      priority = p.priority,
      main = p.main,
      dependencies = p.dependencies,
    },
  }
end

return M
