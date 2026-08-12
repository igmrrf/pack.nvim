local M = {}

local function default_main(name, plugin_dir)
	local base = name:match("^(.+)%.nvim$") or name

	local candidates = { base }
	local underscored = base:gsub("%-", "_")
	if underscored ~= base then
		candidates[#candidates + 1] = underscored
	end

	if plugin_dir and plugin_dir ~= "" then
		local lua_dir = vim.fs.joinpath(plugin_dir, "lua")
		for _, cand in ipairs(candidates) do
			if vim.uv.fs_stat(vim.fs.joinpath(lua_dir, cand, "init.lua"))
				or vim.uv.fs_stat(vim.fs.joinpath(lua_dir, cand .. ".lua"))
			then
				return cand
			end
		end
	end

	return base
end

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

function M.normalize(plugin, config)
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

	local url = plugin[1] or plugin.src
	if type(url) ~= "string" or url == "" then
		return nil
	end

	local name = M.derive_name(plugin)

	local is_local = type(plugin.dir) == "string" and plugin.dir ~= ""

	local full_url = url
	if is_local then
		full_url = vim.fn.expand(plugin.dir)
	elseif url:match("^~") then
		full_url = vim.fn.expand(url)
	elseif not (url:match("^%w[%w+.-]*://") or url:match("^git@") or url:match("^/")) then
		full_url = "https://github.com/" .. url
	end

	local config_fn = plugin.config
	if config_fn == true or (not config_fn and plugin.opts) then
		config_fn = function(_, opts_arg)
			local main = plugin.main
			if not main then
				local state = require("pack.state")
				local rec = state.plugins[name]
				local dir = rec and rec.dir
				if not dir or dir == "" then
					dir = is_local and full_url or vim.fs.joinpath(state.native_opt_dir(), name)
				end
				main = default_main(name, dir)
			end
			if plugin.config == true then
				require(main).setup()
			else
				require(main).setup(opts_arg ~= nil and opts_arg or plugin.opts)
			end
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

	local state = require("pack.state")
	local dir = is_local and full_url or vim.fs.joinpath(state.native_opt_dir(), name)
	local status = "missing"
	if vim.fn.isdirectory(dir) == 1 then
		status = "installed"
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
		status = status,
		dir = dir,
		dependencies = dependencies,
		build = build,
		branch = safe_ref(plugin.branch, "branch", name),
		tag = safe_ref(plugin.tag, "tag", name),
		commit = safe_ref(plugin.commit, "commit", name),
		version = plugin.version,
		sem_version = plugin.sem_version,
		category = plugin.category,
		tags = tags,
		log = {},
		load_time = nil,
		managed = true,
		disabled = plugin.disabled or false,
		is_local = is_local,
		local_dir = is_local and full_url or nil,
		module = plugin.module,
	}
end

return M
