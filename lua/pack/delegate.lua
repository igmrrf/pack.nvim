local state = require("pack.state")

local M = {}

-- Flatten and import user plugin specifications (supporting string modules, table imports, recursive directories).
function M.load_plugins(spec)
	if type(spec) == "table" then
		if spec.import then
			return M.load_plugins(spec.import)
		end
		if not (#spec > 1 or type(spec[1]) == "table") then
			if spec[1] or spec.src then
				return { spec }
			end
			return {}
		end
		local plugins = {}
		for _, item in ipairs(spec) do
			if type(item) == "table" and item.import then
				local imported = M.load_plugins(item.import)
				for _, p in ipairs(imported) do
					table.insert(plugins, p)
				end
			else
				table.insert(plugins, item)
			end
		end
		return plugins
	end

	if type(spec) ~= "string" then
		return {}
	end

	local plugins = {}
	local path = spec:gsub("%.", "/")
	local files = {}

	local user_config_dir = vim.fn.stdpath("config")
	local user_path = vim.fs.joinpath(user_config_dir, "lua", path)
	if vim.fn.isdirectory(user_path) == 1 then
		files = vim.fs.find(function(name) return name:match("%.lua$") end, { path = user_path, type = "file", limit = math.huge })
	end

	if #files == 0 then
		files = vim.api.nvim_get_runtime_file("lua/" .. path .. "/**/*.lua", true)
	end

	if #files == 0 then
		local ok, mod = pcall(require, spec)
		if ok and type(mod) == "table" then
			return M.load_plugins(mod)
		end
		return plugins
	end

	for _, file in ipairs(files) do
		local norm_file = file:gsub("\\", "/")
		local mod_path = norm_file:match("lua/(.*)%.lua$")
		if mod_path then
			local mod_name = mod_path:gsub("/", ".")
			local ok, mod = pcall(require, mod_name)
			if ok and type(mod) == "table" then
				local sub = M.load_plugins(mod)
				for _, p in ipairs(sub) do
					table.insert(plugins, p)
				end
			end
		end
	end
	return plugins
end

-- Collect native specs for non-disabled plugins.
function M.collect_native_specs(plugins_map)
	local specs = {}
	for _, p in pairs(plugins_map) do
		if not p.disabled then
			local ns = state.to_native_spec(p)
			if ns then
				specs[#specs + 1] = ns
			end
		end
	end
	return specs
end

-- Partition array into chunks.
function M.chunk_array(arr, chunk_size)
	local chunks = {}
	for i = 1, #arr, chunk_size do
		local chunk = {}
		for j = i, math.min(i + chunk_size - 1, #arr) do
			table.insert(chunk, arr[j])
		end
		table.insert(chunks, chunk)
	end
	return chunks
end

return M
