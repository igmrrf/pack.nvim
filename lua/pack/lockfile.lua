-- Read-side helpers for native vim.pack's lockfile, plus a repair that realigns
-- recorded revisions to what is actually checked out on disk.
--
-- Native vim.pack owns this file; pack.nvim never writes it during normal
-- operation. The ONLY write here is `repair()`, a manual recovery for the
-- documented case where an update checked out new revisions but the lockfile
-- write did not persist (e.g. a read-only $XDG_CONFIG_HOME at update time),
-- leaving HEAD ahead of the lockfile and :checkhealth vim.pack red. It matches
-- native's serialization (see runtime/lua/vim/pack.lua `lock_write`): JSON with
-- two-space indent, sorted keys, a trailing newline, and every field other than
-- `rev` preserved verbatim (notably `version`, which native stores pre-quoted).
local M = {}

-- Lockfile path is fixed by native vim.pack: stdpath('config')/nvim-pack-lock.json.
function M.path()
	return vim.fs.joinpath(vim.fn.stdpath("config"), "nvim-pack-lock.json")
end

-- Decode the lockfile into a table, or nil (+ reason) if absent/unreadable.
function M.read()
	local path = M.path()
	if vim.fn.filereadable(path) == 0 then
		return nil, "no lockfile"
	end
	local read_ok, lines = pcall(vim.fn.readfile, path)
	if not read_ok then
		return nil, "unreadable"
	end
	local ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
	if not ok or type(decoded) ~= "table" or type(decoded.plugins) ~= "table" then
		return nil, "invalid json"
	end
	return decoded
end

-- Current checked-out HEAD sha of a plugin dir, or nil.
local function head_rev(dir)
	if not dir or dir == "" or vim.fn.isdirectory(dir) == 0 then
		return nil
	end
	local out = vim.fn.systemlist({ "git", "-C", dir, "rev-parse", "HEAD" })
	if vim.v.shell_error ~= 0 or type(out) ~= "table" or not out[1] then
		return nil
	end
	return vim.trim(out[1])
end

-- List plugins whose lockfile `rev` differs from the on-disk HEAD.
-- Returns { { name=, expected=<lock rev>, actual=<HEAD> }, ... }, sorted by name.
-- `opt_dir` is native's install dir (state.native_opt_dir()).
function M.divergences(opt_dir)
	local lock = M.read()
	if not lock then
		return {}
	end
	local names = {}
	for name in pairs(lock.plugins) do
		names[#names + 1] = name
	end
	table.sort(names)

	local diverged = {}
	for _, name in ipairs(names) do
		local entry = lock.plugins[name]
		local expected = type(entry) == "table" and entry.rev or nil
		if type(expected) == "string" and expected ~= "" then
			local dir = vim.fs.joinpath(opt_dir, name)
			local actual = head_rev(dir)
			if actual and actual ~= expected then
				diverged[#diverged + 1] = { name = name, expected = expected, actual = actual }
			end
		end
	end
	return diverged
end

-- Realign the lockfile's recorded revisions to the on-disk HEADs (the inverse of
-- :Pack restore, which rolls disk back to the lockfile). Writes atomically via a
-- temp file + rename. Returns the list of realigned plugin names (possibly empty)
-- or nil + reason on failure.
function M.repair(opt_dir)
	local lock = M.read()
	if not lock then
		return nil, "no readable lockfile"
	end

	local fixed = {}
	for name, entry in pairs(lock.plugins) do
		if type(entry) == "table" and type(entry.rev) == "string" then
			local actual = head_rev(vim.fs.joinpath(opt_dir, name))
			if actual and actual ~= entry.rev then
				entry.rev = actual
				fixed[#fixed + 1] = name
			end
		end
	end
	table.sort(fixed)

	if #fixed == 0 then
		return fixed
	end

	-- Match native's on-disk format exactly so a subsequent native read/write
	-- round-trips cleanly.
	local ok, encoded = pcall(vim.json.encode, lock, { indent = "  ", sort_keys = true })
	if not ok then
		return nil, "encode failed"
	end

	local path = M.path()
	local tmp = path .. ".tmp"
	local write_ok = pcall(vim.fn.writefile, vim.split(encoded, "\n"), tmp)
	if not write_ok then
		pcall(vim.fn.delete, tmp)
		return nil, "write failed"
	end
	local uv = vim.uv or vim.loop
	local rename_ok, err = pcall(function()
		local ok, ren_err = uv.fs_rename(tmp, path)
		if not ok then
			os.remove(path)
			assert(uv.fs_rename(tmp, path), ren_err)
		end
	end)
	if not rename_ok then
		pcall(vim.fn.delete, tmp)
		return nil, "rename failed"
	end
	return fixed
end

-- Write or update a single plugin entry in nvim-pack-lock.json.
function M.update_entry(name, src, dir)
	local lock = M.read() or { version = 1, plugins = {} }
	lock.plugins = lock.plugins or {}

	local rev = head_rev(dir)
	lock.plugins[name] = {
		src = src,
		rev = rev or "",
	}

	local ok, encoded = pcall(vim.json.encode, lock, { indent = "  ", sort_keys = true })
	if not ok then
		return false
	end

	local path = M.path()
	local parent = vim.fs.dirname(path)
	if parent and vim.fn.isdirectory(parent) == 0 then
		vim.fn.mkdir(parent, "p")
	end

	local tmp = path .. ".tmp"
	local write_ok = pcall(vim.fn.writefile, vim.split(encoded, "\n"), tmp)
	if not write_ok then
		pcall(vim.fn.delete, tmp)
		return false
	end
	local uv = vim.uv or vim.loop
	local rename_ok = pcall(function()
		local ok_ren, ren_err = uv.fs_rename(tmp, path)
		if not ok_ren then
			os.remove(path)
			assert(uv.fs_rename(tmp, path), ren_err)
		end
	end)
	if not rename_ok then
		pcall(vim.fn.delete, tmp)
		return false
	end
	return true
end

-- Ensure all on-disk plugins are registered in nvim-pack-lock.json so native
-- vim.pack.add recognizes them as installed instead of trying to re-clone/wipe them.
function M.ensure_synced(plugins_map)
	local lock = M.read() or { version = 1, plugins = {} }
	lock.plugins = lock.plugins or {}
	local dirty = false

	for name, p in pairs(plugins_map) do
		if p.dir and p.dir ~= "" and vim.fn.isdirectory(p.dir) == 1 and p.url and p.url ~= "" then
			if not lock.plugins[name] then
				local rev = head_rev(p.dir)
				lock.plugins[name] = {
					src = p.url,
					rev = rev or "",
				}
				dirty = true
			end
		end
	end

	if not dirty then
		return true
	end

	local ok, encoded = pcall(vim.json.encode, lock, { indent = "  ", sort_keys = true })
	if not ok then
		return false
	end

	local path = M.path()
	local parent = vim.fs.dirname(path)
	if parent and vim.fn.isdirectory(parent) == 0 then
		vim.fn.mkdir(parent, "p")
	end

	local tmp = path .. ".tmp"
	local write_ok = pcall(vim.fn.writefile, vim.split(encoded, "\n"), tmp)
	if not write_ok then
		pcall(vim.fn.delete, tmp)
		return false
	end
	local uv = vim.uv or vim.loop
	local rename_ok = pcall(function()
		local ok_ren, ren_err = uv.fs_rename(tmp, path)
		if not ok_ren then
			os.remove(path)
			assert(uv.fs_rename(tmp, path), ren_err)
		end
	end)
	if not rename_ok then
		pcall(vim.fn.delete, tmp)
		return false
	end
	return true
end

return M
