local state = require("pack.state")

local M = {}

function M.clean(update_ui_cb)
	local ok, native_pack = pcall(function()
		return require("pack").native_pack
	end)
	if not ok or not (native_pack and native_pack.get) then
		return
	end

	local ok_get, managed = pcall(native_pack.get)
	if not ok_get or type(managed) ~= "table" then
		return
	end

	local configured = state.get_plugins()
	local to_delete = {}

	for _, entry in ipairs(managed) do
		local name = entry.spec and entry.spec.name
		if name and not (configured[name] and configured[name].managed) then
			table.insert(to_delete, name)
		end
	end

	if #to_delete == 0 then
		vim.notify("pack: Already clean (no unmanaged plugins found)", vim.log.levels.INFO)
		return
	end

	for _, name in ipairs(to_delete) do
		pcall(function()
			vim.pack.del({ name })
		end)
		vim.notify("pack: Removed unused plugin " .. name)
	end
	update_ui_cb()
end

function M.uninstall(selected_plugins, get_cursor_plugin_fn, clear_select_cb, update_ui_cb)
	local targets = {}
	for name, _ in pairs(selected_plugins) do
		local p = state.get_plugins()[name]
		if p then
			table.insert(targets, p)
		end
	end
	if #targets == 0 then
		local p = get_cursor_plugin_fn()
		if p then
			table.insert(targets, p)
		end
	end

	if #targets == 0 then
		return
	end

	local names = {}
	for _, p in ipairs(targets) do
		table.insert(names, p.name)
	end

	local msg = string.format("Uninstall %d plugin(s) from disk? (%s)", #names, table.concat(names, ", "))
	vim.ui.select({ "No", "Yes" }, { prompt = msg }, function(choice)
		if choice == "Yes" then
			for _, p in ipairs(targets) do
				pcall(function()
					require("pack.loader").remove_triggers(p)
				end)
				state.remove_plugin(p.name)
			end
			pcall(function()
				vim.pack.del(names)
			end)
			clear_select_cb()
			update_ui_cb()
		end
	end)
end

function M.toggle_disabled(current_tab, selected_plugins, get_cursor_plugin_fn, clear_select_cb, update_ui_cb)
	if current_tab == "outdated" then
		return
	end
	local targets = {}
	for name, _ in pairs(selected_plugins) do
		local p = state.get_plugins()[name]
		if p then
			table.insert(targets, p)
		end
	end
	if #targets == 0 then
		local p = get_cursor_plugin_fn()
		if p then
			table.insert(targets, p)
		end
	end

	for _, p in ipairs(targets) do
		if p.managed == false then
			vim.notify(
				"pack: '" .. p.name .. "' is native/adopted — pack.nvim does not control its loading",
				vim.log.levels.WARN
			)
		else
			local new_disabled = not p.disabled
			state.set_disabled(p.name, new_disabled)

			if new_disabled then
				if p.status == "loaded" then
					vim.notify(
						"pack: '" .. p.name .. "' disabled but already loaded - restart Neovim to fully unload it",
						vim.log.levels.WARN
					)
				else
					require("pack.loader").remove_triggers(p)
				end
			else
				require("pack.loader").enable(p)
			end
		end
	end
	clear_select_cb()
	update_ui_cb()
end

function M.update_one(current_tab, selected_plugins, get_cursor_plugin_fn, clear_select_cb)
	local targets = {}
	for name, _ in pairs(selected_plugins) do
		table.insert(targets, name)
	end

	if #targets > 0 then
		clear_select_cb()
		require("pack.async").update_plugins(targets)
		return
	end

	if current_tab ~= "outdated" then
		return
	end
	local p = get_cursor_plugin_fn()
	if p then
		require("pack.async").update_plugin(p)
	end
end

function M.update_all_outdated(current_tab)
	if current_tab ~= "outdated" then
		return
	end
	local names = {}
	for _, p in pairs(state.get_plugins()) do
		if not p.disabled and p.behind and p.behind > 0 then
			table.insert(names, p.name)
		end
	end
	require("pack.async").update_plugins(names)
end

function M.sync_one(selected_plugins, get_cursor_plugin_fn, clear_select_cb, update_ui_cb)
	local targets = {}
	if type(selected_plugins) == "table" then
		for name, _ in pairs(selected_plugins) do
			local p = state.get_plugins()[name]
			if p then
				table.insert(targets, p)
			end
		end
	end
	if #targets == 0 and type(get_cursor_plugin_fn) == "function" then
		local p = get_cursor_plugin_fn()
		if p then
			table.insert(targets, p)
		end
	end
	if #targets == 0 then
		return
	end

	local function do_sync(notified)
		local checking = false
		for _, p in ipairs(targets) do
			if p.checking then
				checking = true
				break
			end
		end

		if checking then
			if not notified then
				vim.notify("pack: Waiting for plugin checks to finish before syncing...", vim.log.levels.INFO)
			end
			vim.defer_fn(function()
				do_sync(true)
			end, 200)
			return
		end

		local to_install = {}
		local to_update = {}
		for _, p in ipairs(targets) do
			if not p.disabled then
				if p.status == "missing" then
					local ns = state.to_native_spec(p)
					if ns then
						table.insert(to_install, ns)
					end
				elseif (p.status == "installed" or p.status == "loaded") and (p.behind == nil or p.behind > 0) then
					-- behind == nil means never checked -- sync must not silently skip
					-- it just because no one has run an outdated check yet.
					table.insert(to_update, p.name)
				end
			end
		end

		if #to_install > 0 then
			require("pack")._install_and_load(to_install, false)
		end
		if #to_update > 0 then
			require("pack.async").update_plugins(to_update)
		end
		if #to_install == 0 and #to_update == 0 then
			local msg = (#targets == 1) and ("pack: '" .. targets[1].name .. "' is already up to date")
				or "pack: selected plugins are already up to date"
			vim.notify(msg, vim.log.levels.INFO)
		end
		if clear_select_cb then
			clear_select_cb()
		end
		if update_ui_cb then
			update_ui_cb()
		end
	end

	do_sync(false)
end

function M.delete_one(selected_plugins, get_cursor_plugin_fn, clear_select_cb, update_ui_cb)
	local targets = {}
	if type(selected_plugins) == "table" then
		for name, _ in pairs(selected_plugins) do
			local p = state.get_plugins()[name]
			if p then
				table.insert(targets, p)
			end
		end
	end
	if #targets == 0 and type(get_cursor_plugin_fn) == "function" then
		local p = get_cursor_plugin_fn()
		if p then
			table.insert(targets, p)
		end
	end
	if #targets == 0 then
		return
	end

	local names = {}
	for _, p in ipairs(targets) do
		table.insert(names, p.name)
		pcall(function()
			require("pack.loader").remove_triggers(p)
		end)
		if p.dir and vim.fn.isdirectory(p.dir) == 1 then
			pcall(vim.fn.delete, p.dir, "rf")
		end
		state.remove_plugin(p.name)
	end

	pcall(function()
		vim.pack.del(names)
	end)

	if #names == 1 then
		vim.notify("pack: Deleted '" .. names[1] .. "' from disk", vim.log.levels.INFO)
	else
		vim.notify("pack: Deleted " .. #names .. " plugins from disk (" .. table.concat(names, ", ") .. ")", vim.log.levels.INFO)
	end

	if clear_select_cb then
		clear_select_cb()
	end
	if update_ui_cb then
		update_ui_cb()
	end
end

function M.delete_all_disabled(clear_select_cb, update_ui_cb)
	local disabled_plugins = {}
	for _, p in pairs(state.get_plugins()) do
		if p.disabled then
			table.insert(disabled_plugins, p)
		end
	end

	if #disabled_plugins == 0 then
		vim.notify("pack: No disabled plugins found to delete", vim.log.levels.INFO)
		return
	end

	local names = {}
	for _, p in ipairs(disabled_plugins) do
		table.insert(names, p.name)
		pcall(function()
			require("pack.loader").remove_triggers(p)
		end)
		state.remove_plugin(p.name)
	end

	pcall(function()
		vim.pack.del(names)
	end)

	if clear_select_cb then
		clear_select_cb()
	end
	if update_ui_cb then
		update_ui_cb()
	end

	vim.notify(
		"Deleted " .. #names .. " disabled plugin(s) from disk. Remember to remove their specs from your Lua config before restarting Neovim.",
		vim.log.levels.WARN,
		{ title = "Pack.nvim" }
	)
end

return M
