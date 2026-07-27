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

-- Single source of truth for a spec's registry key. Used by both normalize()
-- (registration) and loader's dependency resolution so the two can never
-- diverge. Accepts a bare "owner/repo" string, pack.nvim shorthand ({ "o/r",
-- name=/as= }), or native-style ({ src=, name= }). Precedence: as > name >
-- basename of url ([1] or src). Mirrors the naming in normalize().
function M.derive_name(spec)
	if type(spec) == "string" then
		spec = { spec }
	end
	if type(spec) ~= "table" then
		return nil
	end
	local url = spec[1] or spec.src
	local match_name = type(url) == "string" and url:match("/([^/]+)$") or nil
	local name = spec.as or spec.name or (match_name and match_name or url)
	if type(name) == "string" and name:sub(-4) == ".git" then
		name = name:sub(1, -5)
	end
	return name
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
	if type(enabled) == "function" then
		enabled = enabled()
	end
	if enabled == false then
		return nil
	end

	-- Accept both pack.nvim shorthand (url at [1]) and native vim.pack.Spec style
	-- (`src=`). Handling it here means dependencies written either way normalize
	-- too, and `src=` specs keep every pack.nvim field (lazy/event/opts/...).
	local url = plugin[1] or plugin.src
	if type(url) ~= "string" or url == "" then
		return nil
	end

	local name = M.derive_name(plugin)

	-- A `dir=` spec is a LOCAL plugin: native vim.pack never clones it, we add its
	-- directory to runtimepath and source it directly. The `[1]`/`src` value is
	-- just a display name in this case, so `dir` wins as the source of truth.
	local is_local = type(plugin.dir) == "string" and plugin.dir ~= ""

	-- Treat full URLs, scp-style git remotes, file:// URLs, and absolute/home
	-- local paths as-is; only bare "owner/repo" shorthand expands to GitHub.
	local full_url = url
	if is_local then
		full_url = vim.fn.expand(plugin.dir)
	elseif url:match("^~") then
		full_url = vim.fn.expand(url)
	elseif not (url:match("^%w[%w+.-]*://") or url:match("^git@") or url:match("^/")) then
		full_url = "https://github.com/" .. url
	end

	local config_fn = plugin.config
	if not config_fn and plugin.opts then
		local main = plugin.main or default_main(name)
		-- Use the opts passed at load time (loader hands over p.opts) so a runtime
		-- mutation is honored, falling back to the spec's opts if called bare.
		config_fn = function(_, opts_arg)
			require(main).setup(opts_arg ~= nil and opts_arg or plugin.opts)
		end
	end

	local dependencies = plugin.dependencies or {}
	if type(dependencies) == "string" then
		dependencies = { dependencies }
	end

	local build = plugin.build

	local tags = plugin.tags
	if type(tags) == "string" then
		tags = { tags }
	end

	local is_lazy = plugin.lazy
	if is_lazy == nil then
		is_lazy = (plugin.cmd ~= nil or plugin.event ~= nil or plugin.ft ~= nil or plugin.keys ~= nil)
	end

	return {
		url = full_url,
		name = name,
		lazy = is_lazy,
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
		category = plugin.category,
		tags = tags or {},
		dir = "",
		status = "unknown", -- missing, installed, loaded, error, building
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
		is_local = is_local,
		local_dir = is_local and full_url or nil,
		managed = true,
	}
end

-- Whether a spec opts into loading (its `enabled` is not false, evaluating a
-- function form). Used to tell an intentionally-disabled spec apart from a
-- genuinely invalid one so we don't warn about the former.
local function is_enabled(plugin)
	local e = type(plugin) == "table" and plugin.enabled
	if type(e) == "function" then
		e = e()
	end
	return e ~= false
end

function M.add_plugin(p, config)
	local normalized = normalize(p, config)
	if not normalized then
		if is_enabled(p) then
			vim.notify("pack: skipping invalid plugin spec (missing url): " .. vim.inspect(p), vim.log.levels.WARN)
		end
		return {}
	end

	-- A real, explicit registration for this name already exists: this is a
	-- duplicate declaration, ignore it. Anything else (an adopted native stub,
	-- or a stub pulled in only as *someone else's* dependency before this
	-- plugin's own full spec was processed) is upgradable below.
	local existing = M.plugins[normalized.name]
	if existing and existing.managed and not existing.implicit then
		return {}
	end

	local disabled_set = persist.load()
	local queue = { p }
	local added_list = {}

	while #queue > 0 do
		local curr = table.remove(queue, 1)
		local norm = normalize(curr, config)
		if not norm then
			goto continue
		end

		local prev = M.plugins[norm.name]
		if prev and prev.managed and not prev.implicit then
			goto continue
		end

		for _, dep in ipairs(norm.dependencies) do
			table.insert(queue, dep)
		end

		-- Only the top-level spec passed to add_plugin is an explicit
		-- registration; everything reached via `dependencies` is implicit until
		-- (if ever) its own full spec is registered directly, at which point it
		-- upgrades in place below instead of being dropped as a duplicate.
		norm.implicit = curr ~= p

		norm.disabled = disabled_set[norm.name] or false
		-- Native vim.pack owns the install location; this is the authoritative path
		-- it will use. load_fn / reconcile_from_native confirm it post-install, but
		-- computing it here lets us show an accurate status before add() runs.
		-- A local (`dir=`) plugin already carries its own on-disk path -- keep it.
		if not norm.is_local then
			norm.dir = M.native_opt_dir() .. "/" .. norm.name
		else
			norm.dir = norm.local_dir
		end

		if vim.fn.isdirectory(norm.dir) == 1 then
			norm.status = "installed"
		else
			norm.status = "missing"
		end

		if prev then
			-- Upgrade the adopted/implicit stub in place so any table already
			-- holding a reference to `prev` (e.g. a caller's return value) stays valid.
			for k in pairs(prev) do
				prev[k] = nil
			end
			for k, v in pairs(norm) do
				prev[k] = v
			end
			table.insert(added_list, prev)
		else
			M.plugins[norm.name] = norm
			table.insert(added_list, norm)
		end
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
	-- Probe-level error (e.g. a failed upstream fetch). Kept separate from the
	-- plugin's load `status` so a read-only outdated check can surface a problem
	-- without disabling the plugin. Cleared when a later check passes ({}).
	p.outdated_error = detail.error
end

-- Refresh installed-status / on-disk path / recorded revision from what native
-- vim.pack actually has. load_fn already reconciles on add; this is for the
-- dashboard to reflect installs/updates that happened via native afterwards.
function M.find_plugin(name, src)
	if not name and not src then
		return nil
	end
	if name and M.plugins[name] then
		return M.plugins[name]
	end
	for _, p in pairs(M.plugins) do
		if (src and p.url and src:lower() == p.url:lower())
			or (name and p.name and (p.name .. ".nvim" == name or name .. ".nvim" == p.name))
		then
			return p
		end
	end
	return nil
end

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
	-- already in its active set, so our loader never marks it "loaded".
	-- vim.pack.get() reports this authoritatively via `active` (whether the
	-- plugin was added via vim.pack.add() to the current session); fall back to
	-- a runtimepath string match only for callers (older native, test mocks)
	-- that don't set it.
	local rtp = {}
	for _, path in ipairs(vim.api.nvim_list_runtime_paths()) do
		rtp[vim.fs.normalize(path)] = true
	end

	local function is_active(entry)
		if entry.active ~= nil then
			return entry.active
		end
		return entry.path ~= nil and entry.path ~= "" and rtp[vim.fs.normalize(entry.path)] or false
	end

	local adopted = 0
	for _, entry in ipairs(list) do
		local name = entry.spec and entry.spec.name
		if name then
			local p = M.find_plugin(name, entry.spec and entry.spec.src)
			if p then
				-- Managed or already-adopted record: refresh from native, keep `managed`.
				p.dir = entry.path or p.dir
				p.rev = entry.rev or p.rev
				if p.status == "missing" then
					p.status = "installed"
				end
				if p.status == "installed" and is_active(entry) then
					p.status = "loaded"
				end
			else
				-- Unknown to pack.nvim: adopt it (present in native, never declared).
				M.plugins[name] = {
					name = name,
					url = entry.spec and entry.spec.src or nil,
					dir = entry.path or "",
					rev = entry.rev,
					status = is_active(entry) and "loaded"
						or ((entry.path and entry.path ~= "") and "installed" or "missing"),
					managed = false,
					disabled = false,
					lazy = false,
					priority = 50,
					log = {},
					dependencies = {},
					is_local = false,
				}
				adopted = adopted + 1
			end
		end
	end
	if adopted > 0 then
		M.generation = M.generation + 1
	end
end

-- Resolve a pack.nvim plugin's pin fields to native vim.pack's single
-- `version`. Precedence: commit > tag > branch > version/sem_version range.
-- A range string ("^1.0", ">=0.5") becomes a vim.version range object; a plain
-- ref (branch/tag/sha) is passed through as a string, which native accepts.
local function resolve_version(p)
	if p.commit then
		return p.commit
	end
	if p.tag then
		return p.tag
	end
	if p.branch then
		return p.branch
	end
	local range_str = p.version or p.sem_version
	if range_str == nil then
		return nil
	end
	if type(range_str) == "table" then
		return range_str
	end
	local ok, range = pcall(vim.version.range, range_str)
	if ok then
		return range
	end
	vim.notify(
		("pack: '%s' has an invalid version range '%s', ignoring"):format(p.name, tostring(range_str)),
		vim.log.levels.WARN
	)
	return nil
end

local function sanitize_value(val)
	local t = type(val)
	if t == "boolean" or t == "number" or t == "string" then
		return val
	elseif t == "table" then
		local res = {}
		local count = 0
		for k, v in pairs(val) do
			if type(k) == "string" or type(k) == "number" then
				local sv = sanitize_value(v)
				if sv ~= nil then
					res[k] = sv
					count = count + 1
				end
			end
		end
		return count > 0 and res or nil
	end
	return nil
end

-- Translate an internal normalized plugin into a native vim.pack spec. All the
-- lazy-loading / config metadata native has no concept of is stashed under
-- `data` (sanitized for Vimscript C conversion).
function M.to_native_spec(p)
	-- Local plugins are never handed to native vim.pack (nothing to clone).
	if p.is_local then
		return nil
	end
	local raw_data = {
		lazy = p.lazy,
		event = p.event,
		ft = p.ft,
		cmd = p.cmd,
		keys = p.keys,
		pattern = p.pattern,
		opts = p.opts,
		build = type(p.build) == "string" and p.build or nil,
		priority = p.priority,
		main = p.main,
		dependencies = p.dependencies,
	}
	return {
		src = p.url,
		name = p.name,
		version = resolve_version(p),
		data = sanitize_value(raw_data) or {},
	}
end

return M
