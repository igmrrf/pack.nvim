local state = require("pack.state")
local ui = require("pack.ui")

local M = {}

function M.setup_user_command(pack_module)
	vim.api.nvim_create_user_command("Pack", function(opts)
		local args_list = {}
		for word in opts.args:gmatch("%S+") do
			table.insert(args_list, word)
		end
		local subcmd = args_list[1]
		local target = args_list[2]

		if subcmd == "sync" then
			local to_install, to_update = {}, {}
			for name, p in pairs(state.get_plugins()) do
				if not p.disabled and p.managed ~= false and not p.is_local then
					if p.status == "missing" then
						local ns = state.to_native_spec(p)
						if ns then
							to_install[#to_install + 1] = ns
						end
					else
						to_update[#to_update + 1] = name
					end
				end
			end
			if #to_install > 0 then
				pack_module._install_and_load(to_install, false)
			end
			if #to_update > 0 then
				require("pack.async").update_plugins(to_update)
			end
		elseif subcmd == "update" then
			if target then
				if state.get_plugins()[target] then
					pack_module.native_call("update", pack_module.native_pack.update, { target })
				else
					vim.notify("pack: Plugin not found: " .. target, vim.log.levels.ERROR)
				end
			else
				pack_module.native_call("update", pack_module.native_pack.update)
			end
		elseif subcmd == "build" then
			if target then
				local p = state.get_plugins()[target]
				if p then
					require("pack.async").run_build_hook(p, function()
						vim.notify("pack: Built " .. target)
					end)
				else
					vim.notify("pack: Plugin not found: " .. target, vim.log.levels.ERROR)
				end
			else
				for _, p in pairs(state.get_plugins()) do
					require("pack.async").run_build_hook(p, function() end)
				end
				vim.notify("pack: Triggered builds")
			end
		elseif subcmd == "load" then
			if target then
				require("pack.loader").load(target)
				vim.notify("pack: Loaded " .. target)
			end
		elseif subcmd == "delete" then
			if target then
				vim.pack.del({ target })
				vim.notify("pack: Deleted " .. target)
			end
		elseif subcmd == "clean" then
			local ok_get, managed = pcall(function()
				return pack_module.native_pack.get and pack_module.native_pack.get() or {}
			end)
			if not ok_get then
				managed = {}
			end
			local configured = state.get_plugins()
			local removed = 0
			for _, entry in ipairs(managed) do
				local name = entry.spec and entry.spec.name
				if name and not (configured[name] and configured[name].managed) then
					pcall(function()
						vim.pack.del({ name })
					end)
					vim.notify("pack: Removed unused plugin " .. name)
					removed = removed + 1
				end
			end
			if removed == 0 then
				vim.notify("pack: Already clean")
			end
		elseif subcmd == "restore" then
			pack_module.native_call("restore", pack_module.native_pack.update, nil, { target = "lockfile" })
		elseif subcmd == "repair" then
			local ok_lf, lockfile = pcall(require, "pack.lockfile")
			if not ok_lf then
				vim.notify("pack: lockfile helper unavailable", vim.log.levels.ERROR)
				return
			end
			local fixed, err = lockfile.repair(state.native_opt_dir())
			if not fixed then
				vim.notify("pack: repair failed: " .. tostring(err), vim.log.levels.ERROR)
			elseif #fixed == 0 then
				vim.notify("pack: lockfile already matches installed revisions")
			else
				vim.notify(
					("pack: aligned lockfile to installed revisions for %d plugin(s): %s\nRestart Neovim (:restart) for native vim.pack to pick it up."):format(
						#fixed,
						table.concat(fixed, ", ")
					)
				)
			end
		elseif subcmd == "profile" then
			ui.open(pack_module.config)
			ui.show_profile()
		elseif subcmd == "diff" then
			require("pack.async").show_diff()
		else
			ui.open(pack_module.config)
		end
	end, {
		nargs = "*",
		complete = function(ArgLead, CmdLine, CursorPos)
			local args = {}
			for word in CmdLine:sub(1, CursorPos):gmatch("%S+") do
				table.insert(args, word)
			end
			if CmdLine:sub(CursorPos, CursorPos):match("%s") then
				table.insert(args, "")
			end

			if #args <= 2 then
				local subcommands =
					{ "sync", "clean", "restore", "repair", "profile", "diff", "update", "build", "load", "delete" }
				local matches = {}
				for _, cmd in ipairs(subcommands) do
					if cmd:find("^" .. vim.pesc(ArgLead)) then
						table.insert(matches, cmd)
					end
				end
				return matches
			elseif #args == 3 then
				local subcmd = args[2]
				if subcmd == "update" or subcmd == "build" or subcmd == "load" or subcmd == "delete" then
					local matches = {}
					for name, _ in pairs(state.get_plugins()) do
						if name:find("^" .. vim.pesc(ArgLead)) then
							table.insert(matches, name)
						end
					end
					return matches
				end
			end
			return {}
		end,
	})
end

return M
