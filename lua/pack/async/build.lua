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
				local plugin_dir = plugin.dir .. "/plugin"
				if vim.fn.isdirectory(plugin_dir) == 1 then
					for _, f in ipairs(vim.fn.glob(plugin_dir .. "/**/*.{vim,lua}", false, true)) do
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
		local ok, err = pcall(vim.system, shell, { cwd = plugin.dir, text = true }, function(res)
			vim.schedule(function()
				local combined = (res.stdout or "")
				if res.stderr and res.stderr ~= "" then
					combined = combined .. "\n" .. res.stderr
				end
				for line in combined:gmatch("[^\r\n]+") do
					append_log_fn(plugin, line)
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
		if i > #steps then
			local became_loaded = status_before == "loaded" or plugin.status == "loaded"
			local target_status = build_failed and "error" or (became_loaded and "loaded") or "installed"
			state.update_status(plugin.name, target_status)
			plugin.status = target_status
			ui_update()
			return done_cb()
		end
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
