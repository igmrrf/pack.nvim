local state = require("pack.state")

local M = {}

local function ui_update()
	if package.loaded["pack.ui"] then
		require("pack.ui").update()
	end
end

-- Execute an individual build step.
local function run_build_step(plugin, hook, append_log_fn, cb)
	if type(hook) == "function" then
		vim.schedule(function()
			local ok, err = pcall(hook, { path = plugin.dir, spec = plugin })
			if not ok then
				append_log_fn(plugin, "build hook failed: " .. tostring(err))
				vim.notify("pack: build hook failed for " .. plugin.name .. "\n" .. tostring(err), vim.log.levels.ERROR)
				cb(false)
			else
				cb(true)
			end
		end)
	elseif type(hook) == "string" and hook:sub(1, 1) == ":" then
		vim.schedule(function()
			append_log_fn(plugin, "$ " .. hook)
			if plugin.dir and vim.fn.isdirectory(plugin.dir) == 1 then
				vim.opt.rtp:append(plugin.dir)
				local lua_dir = plugin.dir .. "/lua"
				if vim.fn.isdirectory(lua_dir) == 1 then
					local p1 = plugin.dir .. "/lua/?.lua"
					local p2 = plugin.dir .. "/lua/?/init.lua"
					if not package.path:find(p1, 1, true) then
						package.path = package.path .. ";" .. p1 .. ";" .. p2
					end
				end
				if plugin.name then
					local guard_name = "loaded_" .. plugin.name:gsub("[^%w_]", "_")
					vim.g[guard_name] = nil
				end
				local plugin_dir = plugin.dir .. "/plugin"
				if vim.fn.isdirectory(plugin_dir) == 1 then
					local files = vim.fs.find(function(name, _)
						return name:match("%.lua$") or name:match("%.vim$")
					end, { path = plugin_dir, type = "file", limit = math.huge })
					for _, f in ipairs(files) do
						pcall(vim.cmd, "source " .. f)
					end
				end
			end

			local ok, err = pcall(vim.cmd, hook:sub(2))
			if not ok then
				append_log_fn(plugin, "build command failed: " .. tostring(err))
				vim.notify(
					"pack: build command failed for " .. plugin.name .. ": " .. tostring(err),
					vim.log.levels.ERROR
				)
				cb(false)
			else
				cb(true)
			end
		end)
	elseif type(hook) == "string" then
		local shell = vim.fn.has("win32") == 1 and { "cmd", "/c", hook } or { "sh", "-c", hook }
		append_log_fn(plugin, "$ " .. table.concat(shell, " "))

		local partial_stdout = ""
		local partial_stderr = ""

		local function process_stream(chunk, is_err)
			if not chunk or chunk == "" then return end
			local text = (is_err and partial_stderr or partial_stdout) .. chunk
			local lines = {}
			local last_idx = 1
			while true do
				local nl = text:find("\n", last_idx, true)
				if not nl then break end
				local line = text:sub(last_idx, nl - 1)
				if line:sub(-1) == "\r" then line = line:sub(1, -2) end
				table.insert(lines, line)
				last_idx = nl + 1
			end
			if is_err then
				partial_stderr = text:sub(last_idx)
			else
				partial_stdout = text:sub(last_idx)
			end

			if #lines > 0 then
				vim.schedule(function()
					for _, line in ipairs(lines) do
						append_log_fn(plugin, line)
						plugin.last_build_line = line
					end
					ui_update()
				end)
			end
		end

		local ok, err = pcall(vim.system, shell, {
			cwd = plugin.dir,
			text = true,
			stdout = function(sys_err, data)
				if not sys_err and data then
					process_stream(data, false)
				end
			end,
			stderr = function(sys_err, data)
				if not sys_err and data then
					process_stream(data, true)
				end
			end,
		}, function(res)
			vim.schedule(function()
				if partial_stdout ~= "" then
					local line = partial_stdout:sub(-1) == "\r" and partial_stdout:sub(1, -2) or partial_stdout
					append_log_fn(plugin, line)
					plugin.last_build_line = line
				end
				if partial_stderr ~= "" then
					local line = partial_stderr:sub(-1) == "\r" and partial_stderr:sub(1, -2) or partial_stderr
					append_log_fn(plugin, line)
					plugin.last_build_line = line
				end

				if res.code ~= 0 then
					append_log_fn(plugin, "build hook exit code: " .. tostring(res.code))
					vim.notify(
						"pack: build hook failed for " .. plugin.name .. " (exit " .. tostring(res.code) .. ")",
						vim.log.levels.ERROR
					)
					cb(false)
				else
					cb(true)
				end
			end)
		end)
		if not ok then
			append_log_fn(plugin, "could not run build hook: " .. tostring(err))
			vim.notify(
				"pack: could not run build hook for " .. plugin.name .. ": " .. tostring(err),
				vim.log.levels.ERROR
			)
			cb(false)
		end
	else
		cb(true)
	end
end

-- Run build hook(s) for a plugin.
function M.run_build_hook(plugin, append_log_fn, done_cb)
	done_cb = done_cb or function() end
	local build = plugin.build
	if not build then
		return done_cb()
	end

	local status_before = plugin.status
	state.update_status(plugin.name, "building")
	plugin.status = "building"
	ui_update()
	if package.loaded["pack.ui"] then
		require("pack.ui").ensure_spinner()
	end

	local steps = type(build) == "table" and build or { build }
	local i = 0
	local build_failed = false
	local function next_step(step_ok)
		if step_ok == false then
			build_failed = true
		end
		i = i + 1
		if i > #steps or build_failed then
			plugin.build_progress = nil
			plugin.last_build_line = nil
			local became_loaded = status_before == "loaded" or plugin.status == "loaded"
			local target_status = build_failed and "error" or (became_loaded and "loaded") or "installed"
			state.update_status(plugin.name, target_status)
			plugin.status = target_status
			ui_update()
			return done_cb()
		end

		local step_desc = type(steps[i]) == "string" and steps[i] or ("step " .. i)
		plugin.build_progress = {
			current = i,
			total = #steps,
			desc = step_desc,
		}
		ui_update()

		run_build_step(plugin, steps[i], append_log_fn, next_step)
	end
	next_step(true)
end

-- Setup PackChanged autocmd for automatic build hook execution.
function M.setup_build_hooks(run_build_hook_fn, append_log_fn)
	local group = vim.api.nvim_create_augroup("pack_build_hooks", { clear = true })
	vim.api.nvim_create_autocmd("PackChanged", {
		group = group,
		callback = function(ev)
			local d = ev.data
			if not d or (d.kind ~= "install" and d.kind ~= "update") then
				return
			end
			local name = d.spec and d.spec.name
			local p = state.find_plugin(name, d.spec and d.spec.src)
			if not p then
				return
			end
			p.dir = d.path or p.dir
			local function finish_update()
				if d.kind == "update" then
					if p.status_before_update and p.status ~= "error" then
						state.update_status(name, p.status_before_update)
						p.status_before_update = nil
					end
					state.set_behind(name, 0)
					state.set_outdated_detail(name, {})
					ui_update()
				end
			end

			local function maybe_build()
				if p.build then
					run_build_hook_fn(p, finish_update)
				else
					finish_update()
				end
			end

			if d.kind == "install" and p.dir and vim.fn.filereadable(p.dir .. "/.gitmodules") == 1 then
				append_log_fn(p, "$ git submodule update --init --recursive")
				local ok = pcall(
					vim.system,
					{ "git", "submodule", "update", "--init", "--recursive" },
					{ cwd = p.dir },
					function(res)
						vim.schedule(function()
							if res.code ~= 0 then
								vim.notify(
									"pack: submodule init failed for "
										.. p.name
										.. " (exit "
										.. tostring(res.code)
										.. ")",
									vim.log.levels.WARN
								)
							end
							maybe_build()
						end)
					end
				)
				if not ok then
					maybe_build()
				end
			else
				maybe_build()
			end
		end,
	})
end

return M
