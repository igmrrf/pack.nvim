local M = {}

local KEYMAP_OPTS = {
	expr = true,
	noremap = true,
	nowait = true,
	script = true,
	silent = true,
	unique = true,
	desc = true,
}

local seen_cmds = {}

-- Normalize a plugin-level `ft` value ("lua" or {"lua", "markdown"}) to a list.
-- Returns nil when absent so specs without it keep the global-mapping behavior.
local function normalize_ft_list(ft)
	if type(ft) == "string" then
		return ft ~= "" and { ft } or nil
	elseif type(ft) == "table" and #ft > 0 then
		return ft
	end
	return nil
end

-- Normalize keymap specs to standard entry tables.
local function normalize_key_entries(raw)
	local entries = {}
	local list = type(raw) == "table" and raw or { raw }
	for _, k in ipairs(list) do
		if type(k) == "string" then
			table.insert(entries, { lhs = k, rhs = nil, modes = { "n" }, opts = {} })
		else
			local modes = k.mode or "n"
			modes = type(modes) == "table" and modes or { modes }
			local opts = {}
			for key, value in pairs(k) do
				if KEYMAP_OPTS[key] then
					opts[key] = value
				end
			end
			table.insert(entries, { lhs = k[1] or k.lhs, rhs = k[2], modes = modes, opts = opts })
		end
	end
	return entries
end

local function buf_matches_ft(fts, bufnr)
	return vim.api.nvim_buf_is_valid(bufnr) and vim.list_contains(fts, vim.bo[bufnr].filetype)
end

-- Bind a keymap ONLY into OPEN buffers whose filetype matches the plugin's
-- `ft`, and watch FileType so future matching buffers get it too. Both the
-- pre-load lazy placeholder and the post-load real mapping go through here;
-- `make_opts` receives the target bufnr and must return the full
-- vim.keymap.set opts (including `buffer = bufnr`, so no other filetype ever
-- sees the key).
local function bind_ft_scoped(ft_group, fts, modes, lhs, rhs, make_opts)
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if buf_matches_ft(fts, bufnr) then
			for _, mode in ipairs(modes) do
				vim.keymap.set(mode, lhs, rhs, make_opts(bufnr))
			end
		end
	end
	vim.api.nvim_create_autocmd("FileType", {
		group = ft_group,
		pattern = fts,
		callback = function(args)
			for _, mode in ipairs(modes) do
				vim.keymap.set(mode, lhs, rhs, make_opts(args.buf))
			end
		end,
	})
end

-- Set up keymaps for lazy or loaded plugin.
-- opts.rebind marks the post-load re-bind pass (M.load): a bare key (no rhs) there
-- already did its job by loading the plugin, which now owns the real mapping, so skip
-- it silently instead of warning "nothing to bind".
function M.setup_keys(p, load_cb, opts)
	opts = opts or {}
	local entries = normalize_key_entries(p.keys)

	-- A plugin-level `ft` scopes EVERY key entry to matching buffers: no global
	-- mapping is ever created for this plugin's keys. The lazy placeholder only
	-- exists in matching filetypes (so pressing it elsewhere does nothing), and
	-- after load the real mapping stays buffer-local to them as well.
	-- One augroup per plugin, recreated fresh (clear=true) on each setup_keys
	-- call so the post-load rebind pass replaces the placeholder autocmds
	-- instead of stacking on top of them.
	local fts = normalize_ft_list(p.ft)
	local ft_group
	if fts then
		ft_group = vim.api.nvim_create_augroup("pack_trigger_keys_ft_" .. p.name, { clear = true })
	end

	for _, entry in ipairs(entries) do
		local lhs = entry.lhs
		if not lhs then
			vim.notify("pack: '" .. p.name .. "' has a keys entry with no lhs - skipping", vim.log.levels.WARN)
		elseif p.status == "loaded" then
			if entry.rhs == nil then
				if not opts.rebind then
					vim.notify(
						"pack: '"
							.. p.name
							.. "' keys entry '"
							.. lhs
							.. "' has no rhs and the plugin isn't lazy - nothing to bind",
						vim.log.levels.WARN
					)
				end
			elseif fts then
				-- Loaded with an ft-scoped key: bind the real mapping buffer-locally,
				-- only into matching filetypes, and keep honoring future buffers.
				bind_ft_scoped(ft_group, fts, entry.modes, lhs, entry.rhs, function(bufnr)
					return vim.tbl_extend("force", entry.opts, { buffer = bufnr })
				end)
			else
				for _, mode in ipairs(entry.modes) do
					vim.keymap.set(mode, lhs, entry.rhs, entry.opts)
				end
			end
		else
			local function trigger()
				-- Only this buffer's placeholder goes here; load_cb -> remove_triggers
				-- tears down the FileType autocmds and the other buffers' placeholders.
				local del_opts = fts and { buffer = vim.api.nvim_get_current_buf() } or nil
				for _, mode in ipairs(entry.modes) do
					pcall(vim.keymap.del, mode, lhs, del_opts)
				end
				load_cb(p.name)
				local replay = function()
					vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(lhs, true, true, true), "m", false)
				end
				if entry.rhs == nil then
					replay()
				elseif type(entry.rhs) == "function" then
					-- For an ft-scoped key the rebind pass inside load_cb has already
					-- bound the real mapping buffer-locally; a global set() here would
					-- leak it into every other filetype.
					if not fts then
						for _, mode in ipairs(entry.modes) do
							vim.keymap.set(mode, lhs, entry.rhs, entry.opts)
						end
					end
					if entry.opts and entry.opts.expr then
						local res = entry.rhs()
						if type(res) == "string" and res ~= "" then
							vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(res, true, true, true), "m", false)
						end
					else
						entry.rhs()
					end
				else
					if not fts then
						for _, mode in ipairs(entry.modes) do
							vim.keymap.set(mode, lhs, entry.rhs, entry.opts)
						end
					end
					replay()
				end
			end
			-- The placeholder drives nvim_feedkeys/load_cb, not an expression result, so
			-- it must NOT be an <expr> mapping (feedkeys under expr eval hits textlock).
			-- expr/replace_keycodes belong only to the real post-load rebind above.
			local placeholder_base = vim.tbl_extend("force", { desc = "pack: lazy-load " .. p.name }, entry.opts)
			placeholder_base.expr = nil
			placeholder_base.replace_keycodes = nil
			if fts then
				-- Lazy + ft-scoped: NO global placeholder. The key exists only in
				-- buffers whose filetype matches the plugin's `ft`, which is exactly
				-- where pressing it may load the plugin ("keys adhere to ft before
				-- loading").
				bind_ft_scoped(ft_group, fts, entry.modes, lhs, trigger, function(bufnr)
					return vim.tbl_extend("force", placeholder_base, { buffer = bufnr })
				end)
			else
				for _, mode in ipairs(entry.modes) do
					vim.keymap.set(mode, lhs, trigger, placeholder_base)
				end
			end
		end
	end
end

-- Register commands, autocmds, and keymaps that trigger lazy loading.
function M.setup_triggers(p, load_cb)
	local group
	if p.event or p.ft then
		group = vim.api.nvim_create_augroup("pack_trigger_" .. p.name, { clear = true })
	end

	if p.cmd then
		local cmds = type(p.cmd) == "table" and p.cmd or { p.cmd }
		for _, cmd in ipairs(cmds) do
			if seen_cmds[cmd] and seen_cmds[cmd] ~= p.name then
				vim.notify(
					"pack: command '"
						.. cmd
						.. "' already registered by "
						.. seen_cmds[cmd]
						.. ", overwriting for "
						.. p.name,
					vim.log.levels.WARN
				)
			end
			seen_cmds[cmd] = p.name
			vim.api.nvim_create_user_command(cmd, function(args)
				vim.api.nvim_del_user_command(cmd)
				load_cb(p.name)
				local cmd_opts = {
					cmd = cmd,
					args = args.fargs,
					bang = args.bang,
					mods = args.smods,
				}
				if args.range == 2 then
					cmd_opts.range = { args.line1, args.line2 }
				elseif args.range == 1 then
					cmd_opts.range = { args.line1 }
				end
				if args.count and args.count ~= -1 then
					cmd_opts.count = args.count
				end
				if args.reg and args.reg ~= "" then
					cmd_opts.reg = args.reg
				end
				local ok = pcall(vim.cmd, cmd_opts)
				if not ok then
					local cmd_str = cmd
					if args.args and args.args ~= "" then
						cmd_str = cmd_str .. " " .. args.args
					end
					if args.bang then
						cmd_str = cmd_str .. "!"
					end
					pcall(vim.cmd, cmd_str)
				end
			end, { nargs = "*", range = true, bang = true, complete = "file", force = true })
		end
	end

	if p.event then
		local events = type(p.event) == "table" and p.event or { p.event }
		for _, event in ipairs(events) do
			local ev_name = event
			local pat = p.pattern
			if type(event) == "table" then
				ev_name = event.event
				pat = event.pattern or pat
			elseif type(event) == "string" and event:find(" ") then
				ev_name, pat = event:match("^(%S+)%s+(.+)$")
			end

			vim.api.nvim_create_autocmd(ev_name, {
				group = group,
				pattern = pat,
				once = true,
				callback = function()
					load_cb(p.name)
				end,
			})
		end
	end

	if p.ft then
		local fts = type(p.ft) == "table" and p.ft or { p.ft }
		vim.api.nvim_create_autocmd("FileType", {
			group = group,
			pattern = fts,
			once = true,
			callback = function()
				load_cb(p.name)
			end,
		})
	end

	if p.keys then
		M.setup_keys(p, load_cb)
	end
end

-- Tear down triggers when plugin loads or is disabled.
function M.remove_triggers(p)
	pcall(vim.api.nvim_del_augroup_by_name, "pack_trigger_" .. p.name)
	-- ft-scoped keys watchers (placeholder or post-load rebind).
	pcall(vim.api.nvim_del_augroup_by_name, "pack_trigger_keys_ft_" .. p.name)

	if p.cmd then
		local cmds = type(p.cmd) == "table" and p.cmd or { p.cmd }
		for _, cmd in ipairs(cmds) do
			if seen_cmds[cmd] == p.name then
				pcall(vim.api.nvim_del_user_command, cmd)
				seen_cmds[cmd] = nil
			end
		end
	end

	if p.keys then
		local fts = normalize_ft_list(p.ft)
		for _, entry in ipairs(normalize_key_entries(p.keys)) do
			for _, mode in ipairs(entry.modes) do
				if fts then
					-- The mapping is buffer-local: sweep every buffer for it.
					for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
						if vim.api.nvim_buf_is_valid(bufnr) then
							pcall(vim.keymap.del, mode, entry.lhs, { buffer = bufnr })
						end
					end
				else
					pcall(vim.keymap.del, mode, entry.lhs)
				end
			end
		end
	end
end

function M.reset()
	seen_cmds = {}
end

return M
