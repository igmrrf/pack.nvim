local M = {}

-- Resolve version/ref precedence: commit > tag > branch > version range.
local function resolve_version(p)
	if p.commit then
		return p.commit
	end
	if p.tag then
		return p.tag
	end
	if p.branch then
		return p.branch
	end
	local range_str = p.version or p.sem_version
	if range_str == nil then
		return nil
	end
	if type(range_str) == "table" then
		return range_str
	end
	local ok, range = pcall(vim.version.range, range_str)
	if ok then
		return range
	end
	vim.notify(
		("pack: '%s' has an invalid version range '%s', ignoring"):format(p.name, tostring(range_str)),
		vim.log.levels.WARN
	)
	return nil
end

-- Sanitize Lua values for C conversion in native vim.pack.
local function sanitize_value(val)
	local t = type(val)
	if t == "boolean" or t == "number" or t == "string" then
		return val
	elseif t == "table" then
		local num_string_keys, num_number_keys, total_keys = 0, 0, 0
		local temp = {}

		for k, v in pairs(val) do
			local kt = type(k)
			if kt == "string" or kt == "number" then
				local sv = sanitize_value(v)
				if sv ~= nil then
					temp[k] = sv
					total_keys = total_keys + 1
					if kt == "string" then
						num_string_keys = num_string_keys + 1
					else
						num_number_keys = num_number_keys + 1
					end
				end
			end
		end

		if total_keys == 0 then
			return nil
		end

		local is_pure_array = (num_string_keys == 0) and (num_number_keys == total_keys)
		if is_pure_array then
			for i = 1, total_keys do
				if temp[i] == nil then
					is_pure_array = false
					break
				end
			end
		end

		if is_pure_array then
			local res = {}
			for i = 1, total_keys do
				res[i] = temp[i]
			end
			return res
		else
			local res = {}
			for k, v in pairs(temp) do
				res[tostring(k)] = v
			end
			return res
		end
	end
	return nil
end

-- Convert normalized plugin record to native vim.pack spec.
function M.to_native_spec(p)
	if p.is_local then
		return nil
	end
	local raw_data = {
		lazy = p.lazy,
		event = p.event,
		ft = p.ft,
		cmd = p.cmd,
		keys = p.keys,
		pattern = p.pattern,
		opts = p.opts,
		build = type(p.build) == "string" and p.build or nil,
		priority = p.priority,
		main = p.main,
		dependencies = p.dependencies,
	}
	return {
		src = p.url,
		name = p.name,
		version = resolve_version(p),
		data = sanitize_value(raw_data) or {},
	}
end

return M
