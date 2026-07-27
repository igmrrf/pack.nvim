-- `:checkhealth pack` — reports Neovim/vim.pack support, git, the install
-- directory, per-plugin status, and any orphaned plugin directories.
local M = {}

function M.check()
	local health = vim.health
	health.start("pack.nvim")

	-- Neovim / native vim.pack ------------------------------------------------
	local v = vim.version()
	local ver = string.format("%d.%d.%d", v.major, v.minor, v.patch)
	if vim.pack and vim.pack.add then
		health.ok("native vim.pack is available (Neovim " .. ver .. ")")
	else
		health.error(
			"native vim.pack not found (Neovim " .. ver .. ")",
			{ "pack.nvim requires Neovim 0.12+ — upgrade Neovim" }
		)
	end

	-- git ---------------------------------------------------------------------
	if vim.fn.executable("git") == 1 then
		health.ok("git found on PATH")
	else
		health.error("git not found on PATH", { "Install git and ensure it is on your PATH" })
	end

	local ok_state, state = pcall(require, "pack.state")
	if not ok_state then
		health.error("could not load pack.state: " .. tostring(state))
		return
	end

	health.info("install directory: " .. state.native_opt_dir())

	-- Per-plugin status -------------------------------------------------------
	local plugins = state.get_plugins()
	local counts = { loaded = 0, installed = 0, missing = 0, error = 0, updating = 0, disabled = 0, unknown = 0 }
	local total = 0
	for _, p in pairs(plugins) do
		total = total + 1
		if p.disabled then
			counts.disabled = counts.disabled + 1
		elseif counts[p.status] ~= nil then
			counts[p.status] = counts[p.status] + 1
		else
			-- Any unrecognized/"unknown" status still counts toward the total so the
			-- summary reconciles instead of silently dropping the plugin.
			counts.unknown = counts.unknown + 1
		end
		if p.status == "error" and not p.disabled then
			health.warn("plugin failed to load: " .. p.name)
		end
		if p.status == "missing" and not p.disabled then
			health.warn("plugin not installed yet: " .. p.name)
		end
	end
	local summary = string.format(
		"%d plugin(s): %d loaded, %d installed, %d missing, %d error, %d disabled",
		total,
		counts.loaded,
		counts.installed,
		counts.missing,
		counts.error,
		counts.disabled
	)
	if counts.unknown > 0 then
		summary = summary .. string.format(", %d unknown", counts.unknown)
	end
	health.info(summary)
	if counts.error == 0 and counts.missing == 0 then
		health.ok("all configured plugins are installed and loadable")
	end

	-- Orphaned directories ----------------------------------------------------
	if vim.pack and vim.pack.get then
		local ok_get, managed = pcall(vim.pack.get)
		if ok_get and type(managed) == "table" then
			local orphans = {}
			local state = require("pack.state")
			for _, entry in ipairs(managed) do
				local name = entry.spec and entry.spec.name
				local p = state.find_plugin(name, entry.spec and entry.spec.src)
				if name and not p then
					orphans[#orphans + 1] = name
				end
			end
			if #orphans > 0 then
				health.warn(
					string.format("%d unused plugin director(ies) on disk: %s", #orphans, table.concat(orphans, ", ")),
					{ "Run :Pack clean to remove them" }
				)
			else
				health.ok("no orphaned plugin directories")
			end
		end
	end

	-- Lockfile divergence -----------------------------------------------------
	-- HEAD ahead of / behind the recorded lockfile revision. Native's own
	-- :checkhealth vim.pack reports this, but surface it here too with the safe
	-- recovery, since :Pack restore would roll the working tree BACK to the
	-- lockfile (undoing real updates) rather than forward.
	local ok_lock, lockfile = pcall(require, "pack.lockfile")
	if ok_lock then
		local diverged = lockfile.divergences(state.native_opt_dir())
		if #diverged > 0 then
			local names = {}
			for _, d in ipairs(diverged) do
				names[#names + 1] = d.name
			end
			health.warn(
				string.format("%d plugin(s) not at their lockfile revision: %s", #diverged, table.concat(names, ", ")),
				{
					"Run :Pack repair to align the lockfile to the installed revisions",
					"Or :Pack restore to roll the plugins BACK to the lockfile revisions",
				}
			)
		else
			health.ok("all plugins match their lockfile revision")
		end
	end
end

return M
