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

function M.sync_one(get_cursor_plugin_fn, update_ui_cb)
	local p = get_cursor_plugin_fn()
	if not p then
		return
	end
	if p.disabled then
		vim.notify("pack: '" .. p.name .. "' is disabled", vim.log.levels.WARN)
		return
	end
	if p.status == "missing" then
		local ns = state.to_native_spec(p)
		if ns then
			require("pack")._install_and_load({ ns }, false)
		end
	else
		require("pack.async").update_plugin(p)
	end
	if update_ui_cb then
		update_ui_cb()
	end
end

function M.delete_one(get_cursor_plugin_fn, clear_select_cb, update_ui_cb)
	local p = get_cursor_plugin_fn()
	if not p then
		return
	end
	pcall(function()
		require("pack.loader").remove_triggers(p)
	end)
	state.remove_plugin(p.name)
	pcall(function()
		vim.pack.del({ p.name })
	end)
	vim.notify("pack: Deleted '" .. p.name .. "' from disk", vim.log.levels.INFO)
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
