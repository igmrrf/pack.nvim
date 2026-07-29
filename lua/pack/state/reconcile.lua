local M = {}

function M.find_plugin(plugins, name, src)
	if not name and not src then
		return nil
	end
	if name and plugins[name] then
		return plugins[name]
	end
	for _, p in pairs(plugins) do
		if (src and p.url and src:lower() == p.url:lower())
			or (name and p.name and (p.name .. ".nvim" == name or name .. ".nvim" == p.name))
		then
			return p
		end
	end
	return nil
end

function M.reconcile_from_native(plugins, native_pack, incr_generation_cb)
	if not (native_pack and native_pack.get) then
		return
	end
	local ok, list = pcall(native_pack.get)
	if not ok or type(list) ~= "table" then
		return
	end

	local rtp = {}
	for _, path in ipairs(vim.api.nvim_list_runtime_paths()) do
		rtp[vim.fs.normalize(path)] = true
	end

	local function is_active(entry)
		if entry.active ~= nil then
			return entry.active
		end
		return entry.path ~= nil and entry.path ~= "" and rtp[vim.fs.normalize(entry.path)] == true
	end

	local adopted = 0
	for _, entry in ipairs(list) do
		local name = entry.spec and entry.spec.name
		if name then
			local p = M.find_plugin(plugins, name, entry.spec and entry.spec.src)
			if p then
				p.dir = entry.path or p.dir
				p.rev = entry.rev or p.rev
				if p.status == "missing" then
					p.status = "installed"
				end
				if p.status == "installed" and is_active(entry) then
					p.status = "loaded"
				end
			else
				plugins[name] = {
					name = name,
					url = entry.spec and entry.spec.src or nil,
					dir = entry.path or "",
					rev = entry.rev,
					status = is_active(entry) and "loaded"
						or ((entry.path and entry.path ~= "") and "installed" or "missing"),
					managed = false,
					disabled = false,
					lazy = false,
					priority = 50,
					log = {},
					dependencies = {},
					is_local = false,
				}
				adopted = adopted + 1
			end
		end
	end
	if adopted > 0 then
		incr_generation_cb()
	end
end

return M
