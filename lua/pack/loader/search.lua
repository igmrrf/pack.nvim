local state = require("pack.state")

local M = {}

local ftdetect_cache_override = nil
local mod_cache = { gen = -1, map = {} }
local in_ftdetect = false

function M.ftdetect_cache_path()
	return ftdetect_cache_override or vim.fs.joinpath(vim.fn.stdpath("data"), "pack_ftdetect_cache.lua")
end

function M._set_ftdetect_cache_path_for_testing(path)
	ftdetect_cache_override = path
end

function M.build_cache()
	local cache_file = M.ftdetect_cache_path()
	local plugins = state.get_plugins()
	local lines = {}
	for _, p in pairs(plugins) do
		if not p.disabled and p.lazy and (p.status == "installed" or p.status == "loaded") then
			local ftdetect_vim = vim.fn.globpath(p.dir, "ftdetect/*.vim", true, true)
			for _, file in ipairs(ftdetect_vim) do
				table.insert(lines, 'vim.cmd("source " .. ' .. string.format("%q", vim.fn.fnameescape(file)) .. ")")
			end
			local ftdetect_lua = vim.fn.globpath(p.dir, "ftdetect/*.lua", true, true)
			for _, file in ipairs(ftdetect_lua) do
				table.insert(lines, "dofile(" .. string.format("%q", file) .. ")")
			end
		end
	end
	local f = io.open(cache_file, "w")
	if f then
		if #lines > 0 then
			f:write(table.concat(lines, "\n") .. "\n")
		end
		f:close()
	end
end

function M.resolve_plugin(modname)
	if mod_cache.gen ~= state.generation then
		local map = {}
		local plugins = state.get_plugins()
		local names = {}
		for name in pairs(plugins) do
			names[#names + 1] = name
		end
		table.sort(names)
		for _, name in ipairs(names) do
			local p = plugins[name]
			local base = p.main or (name:match("([^/]+)$") or name):gsub("%.nvim$", "")
			map[name] = map[name] or p
			map[name:gsub("-", "_")] = map[name:gsub("-", "_")] or p
			map[base] = map[base] or p
			map[base:gsub("-", "_")] = map[base:gsub("-", "_")] or p
			local head = base:match("^([^.]+)")
			if head and head ~= base then
				map[head] = map[head] or p
				map[head:gsub("-", "_")] = map[head:gsub("-", "_")] or p
			end
		end
		mod_cache.map = map
		mod_cache.gen = state.generation
	end
	local map = mod_cache.map
	local head = modname:match("^([^.]+)")
	return map[modname] or map[modname:gsub("-", "_")] or (head and map[head]) or (head and map[head:gsub("-", "_")])
end

function M.setup_package_searcher(load_cb)
	in_ftdetect = true
	pcall(dofile, M.ftdetect_cache_path())
	in_ftdetect = false

	if not M._searcher_installed then
		local searcher = function(modname)
			if in_ftdetect then
				return nil
			end
			local target_p = M.resolve_plugin(modname)

			if target_p then
				if target_p.disabled then
					local level = 1
					local in_pcall = false
					while true do
						local info = debug.getinfo(level, "fn")
						if not info then
							break
						end
						if info.func == pcall or info.func == xpcall then
							in_pcall = true
							break
						end
						level = level + 1
					end

					if in_pcall then
						return nil
					end

					return function()
						local function make_mock()
							local mock = {}
							setmetatable(mock, {
								__index = function()
									return make_mock()
								end,
								__call = function()
									return make_mock()
								end,
							})
							return mock
						end
						return make_mock()
					end
				elseif target_p.status == "installed" and target_p.lazy and target_p.module ~= false then
					load_cb(target_p.name)
					return nil
				end
			end
		end
		local searchers = package.loaders or package.searchers
		table.insert(searchers, 1, searcher)
		M._searcher_fn = searcher
		M._searcher_installed = true
	end
end

-- Remove the package searcher installed by setup_package_searcher. Mainly for test
-- isolation: the searcher is process-global and resolves against the live registry,
-- so leaving it installed lets one test's lazy set leak into the next.
function M.uninstall_searcher()
	local searchers = package.loaders or package.searchers
	if M._searcher_fn then
		for i, fn in ipairs(searchers) do
			if fn == M._searcher_fn then
				table.remove(searchers, i)
				break
			end
		end
	end
	M._searcher_fn = nil
	M._searcher_installed = nil
end

function M.reset_cache()
	mod_cache = { gen = -1, map = {} }
end

return M
