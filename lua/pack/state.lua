local persist = require("pack.persist")

local M = {}

M.plugins = {}

-- Bumped whenever the set of registered plugins changes (add/remove). Consumers
-- that cache derived views (e.g. loader's module->plugin map) compare against
-- this to know when to rebuild instead of rescanning on every lookup.
M.generation = 0

local native_opt_dir_override = nil

function M.native_opt_dir()
	return native_opt_dir_override or vim.fs.joinpath(vim.fn.stdpath("data"), "site", "pack", "core", "opt")
end

function M._set_native_opt_dir_for_testing(path)
	native_opt_dir_override = path
end

local norm_mod = require("pack.state.normalize")

function M.derive_name(spec)
	return norm_mod.derive_name(spec)
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
	local normalized = norm_mod.normalize(p, config)
	if not normalized then
		if is_enabled(p) then
			vim.notify("pack: skipping invalid plugin spec (missing url): " .. vim.inspect(p), vim.log.levels.WARN)
		end
		return {}
	end

	local existing = M.plugins[normalized.name]
	if existing and existing.managed and not existing.implicit then
		return {}
	end

	local disabled_set = persist.load()
	local queue = { p }
	local added_list = {}

	while #queue > 0 do
		local curr = table.remove(queue, 1)
		local norm = norm_mod.normalize(curr, config)
		if not norm then
			goto continue
		end

		local prev = M.plugins[norm.name]
		if not prev and norm.url then
			for _, existing_plug in pairs(M.plugins) do
				if existing_plug.url and existing_plug.url:lower() == norm.url:lower() then
					prev = existing_plug
					break
				end
			end
		end

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
			norm.dir = vim.fs.joinpath(M.native_opt_dir(), norm.name)
		else
			norm.dir = norm.local_dir
		end

		if vim.fn.isdirectory(norm.dir) == 1 then
			norm.status = "installed"
		else
			norm.status = "missing"
		end

		if prev then
			if prev.name and prev.name ~= norm.name then
				M.plugins[prev.name] = nil
			end
			-- Upgrade the adopted/implicit stub in place so any table already
			-- holding a reference to `prev` (e.g. a caller's return value) stays valid.
			for k in pairs(prev) do
				prev[k] = nil
			end
			for k, v in pairs(norm) do
				prev[k] = v
			end
			M.plugins[norm.name] = prev
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
	persist.set_disabled(name, false)
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
local reconcile_mod = require("pack.state.reconcile")

function M.find_plugin(name, src)
	return reconcile_mod.find_plugin(M.plugins, name, src)
end

function M.reconcile_from_native(native_pack)
	return reconcile_mod.reconcile_from_native(M.plugins, native_pack, function()
		M.generation = M.generation + 1
	end)
end

local translate = require("pack.state.translate")

function M.to_native_spec(p)
	return translate.to_native_spec(p)
end

return M
