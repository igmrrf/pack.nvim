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

-- Set up keymaps for lazy or loaded plugin.
-- opts.rebind marks the post-load re-bind pass (M.load): a bare key (no rhs) there
-- already did its job by loading the plugin, which now owns the real mapping, so skip
-- it silently instead of warning "nothing to bind".
function M.setup_keys(p, load_cb, opts)
	opts = opts or {}
	for _, entry in ipairs(normalize_key_entries(p.keys)) do
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
			else
				for _, mode in ipairs(entry.modes) do
					vim.keymap.set(mode, lhs, entry.rhs, entry.opts)
				end
			end
		else
			local function trigger()
				for _, mode in ipairs(entry.modes) do
					pcall(vim.keymap.del, mode, lhs)
				end
				load_cb(p.name)
				local replay = function()
					vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(lhs, true, true, true), "m", false)
				end
				if entry.rhs == nil then
					replay()
				elseif type(entry.rhs) == "function" then
					for _, mode in ipairs(entry.modes) do
						vim.keymap.set(mode, lhs, entry.rhs, entry.opts)
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
					for _, mode in ipairs(entry.modes) do
						vim.keymap.set(mode, lhs, entry.rhs, entry.opts)
					end
					replay()
				end
			end
			-- The placeholder drives nvim_feedkeys/load_cb, not an expression result, so
			-- it must NOT be an <expr> mapping (feedkeys under expr eval hits textlock).
			-- expr/replace_keycodes belong only to the real post-load rebind above.
			local placeholder_opts = vim.tbl_extend("force", { desc = "pack: lazy-load " .. p.name }, entry.opts)
			placeholder_opts.expr = nil
			placeholder_opts.replace_keycodes = nil
			for _, mode in ipairs(entry.modes) do
				vim.keymap.set(mode, lhs, trigger, placeholder_opts)
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
		for _, entry in ipairs(normalize_key_entries(p.keys)) do
			for _, mode in ipairs(entry.modes) do
				pcall(vim.keymap.del, mode, entry.lhs)
			end
		end
	end
end

function M.reset()
	seen_cmds = {}
end

return M
