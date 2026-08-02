local state = require("pack.state")

local M = {}

local search_mod = require("pack.loader.search")
local triggers_mod = require("pack.loader.triggers")

function M.setup_triggers(p)
	triggers_mod.setup_triggers(p, function(name)
		M.load(name)
	end)
end

function M.remove_triggers(p)
	triggers_mod.remove_triggers(p)
end

function M.enable(p)
	if p.status == "loaded" then
		return
	end
	if p.lazy then
		M.setup_triggers(p)
	else
		M.load(p.name)
	end
end

local function gen_helptags(dir)
	if not dir or dir == "" then
		return
	end
	local doc = dir .. "/doc"
	if vim.fn.isdirectory(doc) == 1 and #vim.fn.globpath(doc, "*.txt", true, true) > 0 then
		pcall(vim.cmd, "helptags " .. vim.fn.fnameescape(doc))
	end
end

local function packadd(name)
	local ok, err = pcall(vim.cmd.packadd, name)
	if not ok then
		vim.notify("Error loading plugin " .. name .. ": " .. tostring(err), vim.log.levels.ERROR)
	end
	return ok
end

local function load_local(p)
	if not p.dir or p.dir == "" or vim.fn.isdirectory(p.dir) == 0 then
		vim.notify(
			"pack: local plugin directory not found for " .. p.name .. ": " .. tostring(p.dir),
			vim.log.levels.ERROR
		)
		return false
	end
	vim.opt.runtimepath:append(p.dir)
	for _, pat in ipairs({ "plugin/**/*.vim", "plugin/**/*.lua" }) do
		for _, file in ipairs(vim.fn.globpath(p.dir, pat, true, true)) do
			local ok, err = pcall(vim.cmd, "source " .. vim.fn.fnameescape(file))
			if not ok then
				vim.notify("pack: error sourcing " .. file .. ": " .. tostring(err), vim.log.levels.ERROR)
			end
		end
	end
	return true
end

function M._set_ftdetect_cache_path_for_testing(path)
	search_mod._set_ftdetect_cache_path_for_testing(path)
end

function M.build_cache()
	search_mod.build_cache()
end

function M.init(config)
	search_mod.setup_package_searcher(function(name)
		M.load(name)
	end)
end

-- Plugins recorded by load_fn during vim.pack.add, awaiting our ordered load.
local pending = {}

-- Passed to vim.pack.add as its `load` callback. Native invokes this per plugin
-- instead of packadd-ing it (so nothing lands on 'runtimepath' or gets sourced).
-- We only record the plugin + its resolved on-disk path; actual loading happens
-- in flush_pending() after add() returns, so we control order and laziness.
function M.load_fn(data)
	local name = data.spec and data.spec.name
	local p = state.find_plugin(name, data.spec and data.spec.src)
	if p then
		p.dir = data.path
		if p.status ~= "loaded" then
			p.status = "installed"
		end
	end
	table.insert(pending, { name = p and p.name or name, path = data.path })
end

-- Enqueue local (`dir=`) plugins for loading. They never pass through native's
-- load_fn (nothing is cloned), so flush_pending would otherwise never see them.
-- Idempotent across calls: a plugin already "loaded" is skipped.
function M.queue_local_plugins()
	for name, p in pairs(state.get_plugins()) do
		if p.is_local and not p.disabled and p.status ~= "loaded" then
			if p.dir and p.dir ~= "" and vim.fn.isdirectory(p.dir) == 1 then
				p.status = "installed"
				table.insert(pending, { name = name, path = p.dir })
			end
		end
	end
end

-- Load everything recorded by load_fn. Eager plugins load first, highest
-- priority first; lazy plugins get their triggers wired instead. `cond` gates
-- both. Mirrors the old startup loop but driven by native's add() callback.
function M.flush_pending()
	local eager = {}
	for _, item in ipairs(pending) do
		local p = state.get_plugins()[item.name]
		if p and not p.disabled and p.status ~= "loaded" then
			local cond_ok = true
			if p.cond ~= nil then
				local cond_val = type(p.cond) == "function" and p.cond({ path = p.dir, spec = p }) or p.cond
				cond_ok = cond_val and true or false
			end
			if cond_ok then
				if p.init_hook then
					pcall(p.init_hook, { path = p.dir, spec = p })
				end
				if p.lazy then
					M.setup_triggers(p)
				elseif p.implicit then
					-- Reached ONLY as another plugin's `dependency` and given no trigger
					-- of its own: it must load WITH its parent (M.load pulls dependencies
					-- in first), never eagerly at startup. Staying dormant here is what
					-- keeps a lazy plugin's deps (e.g. mason for a lazy lspconfig) from
					-- dragging the whole tree in at startup.
				else
					table.insert(eager, p)
				end
			end
		end
	end

	table.sort(eager, function(a, b)
		-- Highest priority first; break ties by name so equal-priority plugins load
		-- in a stable order across runs (pairs()/native ordering is nondeterministic).
		if a.priority ~= b.priority then
			return a.priority > b.priority
		end
		return a.name < b.name
	end)

	for _, p in ipairs(eager) do
		-- cond was already evaluated above; don't re-run it (side effects).
		-- M.load itself (re)binds `keys` once the plugin is loaded.
		M.load(p.name, { cond_checked = true })
	end

	pending = {}

	-- Regenerate the ftdetect precompile cache now that the installed/lazy set is
	-- settled. pcall so a write failure never breaks startup.
	pcall(M.build_cache)
end

-- Names currently mid-load. Guards the dependency recursion against circular
-- (A->B->A) or diamond specs that would otherwise re-enter an un-"loaded"
-- plugin forever and overflow the stack. Cleared as soon as the deps loop
-- finishes; from there the "loaded" status guard handles re-entry.
local loading = {}

function M.load(name, opts)
	opts = opts or {}
	local plugins = state.get_plugins()
	local p = plugins[name]
	-- "error" plugins already failed to packadd; retrying just re-notifies on
	-- every trigger. A real (re)install resets status to "installed" via load_fn.
	if not p or p.status == "loaded" or p.status == "error" then
		return
	end
	-- Never packadd/config a disabled plugin, even when reached as a dependency
	-- or via :Pack load. disabled is otherwise only honored at flush/collect time.
	if p.disabled then
		return
	end
	if loading[name] then
		return
	end
	loading[name] = true

	if p.dependencies then
		for _, dep in ipairs(p.dependencies) do
			-- Resolve via the same helper registration uses, so a dependency written
			-- native-style ({ src=, name= }) or aliased ({ "o/r", name= }) resolves to
			-- the key it was actually registered under.
			local dep_name = state.derive_name(dep)
			if dep_name then
				M.load(dep_name)
			end
		end
	end

	if p.cond ~= nil and not opts.cond_checked then
		local cond_val = type(p.cond) == "function" and p.cond({ path = p.dir, spec = p }) or p.cond
		if not cond_val then
			loading[name] = nil
			return
		end
	end

	-- A lazy plugin can be force-loaded (as another plugin's dependency, or via
	-- :Pack load) while its triggers are still registered; tear them down so a
	-- stale command/keymap/autocmd doesn't fire against an already-loaded plugin.
	if p.lazy then
		pcall(M.remove_triggers, p)
	end

	local start_time = vim.uv.hrtime()
	local loaded_ok = p.is_local and load_local(p) or (not p.is_local and packadd(name))
	if loaded_ok then
		state.update_status(name, "loaded")
		gen_helptags(p.dir)
		local elapsed = (vim.uv.hrtime() - start_time) / 1e6

		if p.config then
			local config_start = vim.uv.hrtime()
			local ok, err = pcall(p.config, { path = p.dir, spec = p }, p.opts)
			p.load_time = elapsed + (vim.uv.hrtime() - config_start) / 1e6
			if not ok then
				vim.notify("Error loading config for " .. name .. ": " .. tostring(err), vim.log.levels.ERROR)
			end
		else
			p.load_time = elapsed
		end
		-- Rebind every `keys` entry for real now that the plugin is loaded --
		-- regardless of what caused the load (its own key, an event/cmd trigger,
		-- a dependency force-load, :Pack load, require()). remove_triggers above
		-- already tore down the lazy placeholders; without this they'd just stay
		-- gone since only the specific key that was pressed (if any) rebinds itself.
		if p.keys then
			triggers_mod.setup_keys(p, function(name)
				M.load(name)
			end, { rebind = true })
		end
	else
		-- packadd/local-load failed: record it so triggers stop re-attempting.
		state.update_status(name, "error")
	end

	loading[name] = nil

	if package.loaded["pack.ui"] then
		require("pack.ui").update()
	end
end
function M._reset_for_testing()
	pending = {}
	loading = {}
	triggers_mod.reset()
	search_mod.reset_cache()
	search_mod.uninstall_searcher()
end

return M
