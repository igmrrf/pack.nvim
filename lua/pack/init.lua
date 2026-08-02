local state = require("pack.state")
local ui = require("pack.ui")
local loader = require("pack.loader")

local M = {}

M.config = {
	-- Install location and lockfile are owned by native vim.pack and are not
	-- configurable, so they are intentionally not part of this config table.
	performance = {
		vim_loader = true,
	},
	plugins = {},
	ui = {
		border = "rounded",
		auto_open = true, -- Automatically open dashboard float when uninstalled plugins exist
		silent = nil, -- Silences native vim.pack cmdline messages. If nil, defaults to auto_open
		filter = "default", -- "default" (vim.ui.input) or "input" (vim.fn.input)
		icons = {
			loaded = "●",
			not_loaded = "○",
			error = "✖",
			sync = "↺",
		},
	},
}

local function should_silence(msg)
	if type(msg) ~= "string" then
		return false
	end
	return msg:match("^vim%.pack") ~= nil
		or msg:match("vim%.pack%.") ~= nil
		or msg:find("vim.pack", 1, true) ~= nil
		or msg:match("^Submodule%s+'") ~= nil
		or msg:find("registered for path", 1, true) ~= nil
		or msg:match("^Cloning into%s+'") ~= nil
		or msg:find("Cloning into", 1, true) ~= nil
end

-- Silence native Neovim `vim.pack` cmdline notifications and stdout print/echo messages
-- when silent=true or when auto_open=true (where dashboard float is the indicator).
if not _G.__pack_silent_hooks_installed then
	_G.__pack_silent_hooks_installed = true

	local orig_notify = vim.notify
	vim.notify = function(msg, level, opts)
		local is_silent = (M.config and M.config.ui and M.config.ui.silent ~= nil) and M.config.ui.silent
			or (M.config and M.config.ui and M.config.ui.auto_open ~= false)

		if is_silent then
			if opts and opts.title == "vim.pack" then
				return
			end
			if should_silence(msg) then
				return
			end
		end
		return orig_notify(msg, level, opts)
	end

	local orig_print = print
	_G.print = function(...)
		local is_silent = (M.config and M.config.ui and M.config.ui.silent ~= nil) and M.config.ui.silent
			or (M.config and M.config.ui and M.config.ui.auto_open ~= false)

		if is_silent then
			local args = { ... }
			for _, arg in ipairs(args) do
				if should_silence(arg) then
					return
				end
			end
		end
		return orig_print(...)
	end

	local orig_echo = vim.api.nvim_echo
	vim.api.nvim_echo = function(chunks, history, opts)
		local is_silent = (M.config and M.config.ui and M.config.ui.silent ~= nil) and M.config.ui.silent
			or (M.config and M.config.ui and M.config.ui.auto_open ~= false)

		if is_silent and type(chunks) == "table" then
			for _, chunk in ipairs(chunks) do
				if type(chunk) == "table" and type(chunk[1]) == "string" and should_silence(chunk[1]) then
					return
				end
			end
		end
		return orig_echo(chunks, history, opts)
	end
end

local delegate = require("pack.delegate")

local function load_plugins(spec)
	return delegate.load_plugins(spec)
end

M._load_plugins = load_plugins

-- Bulk-register keymaps: { { lhs, rhs, mode = "n"|{...}, desc = "...", ... }, ... }
function M.map_keys(keys)
	for _, k in ipairs(keys) do
		local mode = k.mode or "n"
		local opts = {}
		for key, value in pairs(k) do
			if type(key) == "string" and key ~= "mode" then
				opts[key] = value
			end
		end
		vim.keymap.set(mode, k[1], k[2], opts)
	end
end

local function collect_native_specs(plugins_map)
	return delegate.collect_native_specs(plugins_map)
end

local function chunk_array(arr, chunk_size)
	return delegate.chunk_array(arr, chunk_size)
end

-- Hand a batch of native specs to native vim.pack (which clones/checks out and
-- calls loader.load_fn per plugin instead of sourcing), then run our ordered
-- loader. Native never touches runtimepath - we own all loading.
function M._install_and_load(native_specs, confirm)
	if M.native_pack and M.native_pack.add and #native_specs > 0 then
		local missing_specs = {}
		local installed_specs = {}

		for _, spec in ipairs(native_specs) do
			local p = state.find_plugin(spec.name, spec.src)
			if p and (not p.dir or p.dir == "" or vim.fn.isdirectory(p.dir) == 0) then
				state.update_status(p.name, "installing")
				table.insert(missing_specs, spec)
			else
				table.insert(installed_specs, spec)
			end
		end

		if #installed_specs > 0 then
			local chunks = chunk_array(installed_specs, 10)
			for _, chunk in ipairs(chunks) do
				local ok, err = pcall(M.native_pack.add, chunk, { load = loader.load_fn, confirm = confirm, silent = true })
				if not ok then
					vim.notify("pack: native vim.pack.add failed: " .. tostring(err), vim.log.levels.WARN)
				end
			end
		end

		if #missing_specs > 0 then
			local do_install_missing = function()
				local auto_open = M.config and M.config.ui and (M.config.ui.auto_open ~= false)
				if auto_open then
					pcall(function()
						require("pack.ui").open(M.config, { auto_opened = true })
					end)
				end

				local chunks = chunk_array(missing_specs, 10)
				for _, chunk in ipairs(chunks) do
					local ok, err = pcall(M.native_pack.add, chunk, { load = loader.load_fn, confirm = confirm, silent = true })
					if not ok then
						vim.notify("pack: native vim.pack.add failed: " .. tostring(err), vim.log.levels.WARN)
					end
				end

				loader.flush_pending()
				if package.loaded["pack.ui"] then
					pcall(function()
						require("pack.ui").update({ jump_to_first = true })
					end)
				end
			end

			if vim.v.vim_did_init == 0 then
				vim.api.nvim_create_autocmd("VimEnter", {
					once = true,
					callback = function()
						vim.defer_fn(do_install_missing, 50)
					end,
				})
			else
				do_install_missing()
			end
		end
	end
	-- Local (dir=) plugins never reach native; enqueue them for the same ordered
	-- load pass so they load at startup like everything else.
	loader.queue_local_plugins()
	loader.flush_pending()
end

-- Public add: accepts pack.nvim shorthand ({ "u/r", lazy=true }) or native-style
-- specs ({ src=..., name=..., version=... }), registers them in state, and
-- installs+loads any newly-added, non-disabled plugins via native vim.pack.
function M.add(specs)
	local items = specs
	if type(specs) == "string" then
		items = { specs }
	elseif type(specs) == "table" then
		if not (#specs > 1 or type(specs[1]) == "table") then
			if specs[1] or specs.src then
				items = { specs }
			end
		end
	end

	local added = {}
	for _, item in ipairs(items) do
		local raw = item
		if type(item) == "string" then
			raw = { item }
		end
		-- Native-style ({ src=..., name=..., lazy=..., opts=... }) and shorthand
		-- ({ "owner/repo", lazy=..., opts=... }) both pass through untouched;
		-- normalize() reads url from [1] or src and keeps all pack.nvim fields.
		local newly = state.add_plugin(raw, M.config)
		for _, ap in ipairs(newly) do
			added[#added + 1] = ap
		end
	end

	if #added > 0 then
		local specs_to_add = {}
		for _, p in ipairs(added) do
			if not p.disabled then
				local ns = state.to_native_spec(p)
				if ns then
					specs_to_add[#specs_to_add + 1] = ns
				end
			end
		end
		M._install_and_load(specs_to_add, false)
	end
end

-- pcall wrapper for native vim.pack calls. Its API is still evolving in Neovim
-- nightly, so a signature/option change (e.g. update's `target`/`force`) would
-- otherwise throw straight out of a :Pack command with no user-facing message.
local function native_call(desc, fn, ...)
	if type(fn) ~= "function" then
		vim.notify("pack: native vim.pack." .. desc .. " is unavailable", vim.log.levels.ERROR)
		return false
	end
	local ok, err = pcall(fn, ...)
	if not ok then
		vim.notify("pack: " .. desc .. " failed: " .. tostring(err), vim.log.levels.ERROR)
	end
	return ok
end

M.native_call = native_call

function M.setup(opts)
	-- Extract the raw plugins spec but DO NOT resolve it yet; load_plugins must run
	-- after the wrapper is installed so imperative `vim.pack.add` files register.
	-- Copy `plugins` out instead of nil-ing it on the caller's table: setup must not
	-- mutate the opts the user passed in (it may be shared/reused).
	local raw_plugins = opts and opts.plugins or nil
	local merge_opts = opts
	if opts and opts.plugins ~= nil then
		merge_opts = {}
		for k, v in pairs(opts) do
			if k ~= "plugins" then
				merge_opts[k] = v
			end
		end
	end
	M.config = vim.tbl_deep_extend("force", M.config, merge_opts or {})
	if M.config.performance and M.config.performance.vim_loader and vim.loader then
		vim.loader.enable()
	end

	-- Delegate all git operations to native vim.pack (preserved on M.native_pack).
	-- Guard re-entrant setup (e.g. `:source $MYVIMRC`): on the second call vim.pack
	-- is already OUR wrapper. Adopting it as native would make native_pack.add/
	-- update/del recurse into the wrapper forever (and drop the load callback, so
	-- real installs silently no-op). Detect the wrapper by its tag and reuse the
	-- real native we preserved the first time; otherwise adopt whatever vim.pack
	-- currently is (real native, or a test's fake) and remember it as the real one.
	if rawget(vim.pack, "__pack_wrapper") and M._real_native then
		M.native_pack = M._real_native
	else
		M.native_pack = vim.pack
		M._real_native = vim.pack
	end
	if not (M.native_pack and M.native_pack.add) then
		vim.notify("pack.nvim requires Neovim 0.12+ (native vim.pack)", vim.log.levels.ERROR)
		return
	end

	loader.init(M.config)
	require("pack.async").setup_build_hooks()

	-- Establish a clean state table ONCE, before the wrapper is installed, so a
	-- re-setup()/test starts fresh and any nested vim.pack.add during load_plugins
	-- lands on an empty table. We deliberately do NOT call state.init again after
	-- load_plugins: that would wipe records the wrapper registered during import.
	state.init({ plugins = {} })

	-- Lazy-aware wrapper installed BEFORE load_plugins so imperative vim.pack.add
	-- calls (including files pulled in by `import`) route through pack.nvim.
	vim.pack = setmetatable({ __pack_wrapper = true }, { __index = M.native_pack })
	vim.pack.add = function(specs)
		M.add(specs)
	end
	vim.pack.del = function(names, opts)
		if type(names) == "string" then
			names = { names }
		end
		opts = vim.tbl_extend("force", { force = true }, opts or {})
		for _, name in ipairs(names) do
			local p = state.get_plugins()[name]
			if p then
				pcall(function()
					loader.remove_triggers(p)
				end)
				if p.dir and vim.fn.isdirectory(p.dir) == 1 then
					pcall(vim.fn.delete, p.dir, "rf")
				end
				state.remove_plugin(name)
			end
		end
		if type(M.native_pack.del) == "function" then
			pcall(M.native_pack.del, names, opts)
		end
	end
	vim.pack.update = function(names, update_opts)
		native_call("update", M.native_pack.update, names, update_opts)
	end

	-- Now that the wrapper is live, resolve declarative specs and any imperative
	-- files (which call the wrapped vim.pack.add and register as they load).
	local plugins = load_plugins(raw_plugins)
	M.config.plugins = plugins or M.config.plugins

	-- Register declarative specs ADDITIVELY. add_plugin dedups by name, so any
	-- plugin an imperative import already registered (managed=true) via the
	-- wrapper is preserved with its full metadata and not clobbered/double-added.
	for _, p in ipairs(M.config.plugins) do
		state.add_plugin(p, M.config)
	end

	-- Install (native) + load (ours) every configured, non-disabled plugin.
	M._install_and_load(collect_native_specs(state.get_plugins()), false)

	require("pack.commands").setup_user_command(M)
end

return M
