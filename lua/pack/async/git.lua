local M = {}

-- Run a git command asynchronously.
function M.git(plugin, args, cwd, max_log_lines, git_timeout, append_log_fn, on_done)
	append_log_fn(plugin, "$ git " .. table.concat(args, " "))
	local cmd = vim.iter({ { "git" }, args }):flatten():totable()

	local accumulated = {}
	local line_buffer = ""
	local safe_append = vim.schedule_wrap(append_log_fn)

	local function handle_chunk(data)
		if not data then
			return
		end
		table.insert(accumulated, data)
		line_buffer = line_buffer .. data
		while true do
			local pos = line_buffer:find("[\r\n]")
			if not pos then
				break
			end
			local line = line_buffer:sub(1, pos - 1)
			line_buffer = line_buffer:sub(pos + 1)
			if line ~= "" then
				safe_append(plugin, line)
			end
		end
	end

	local ok, err = pcall(vim.system, cmd, {
		cwd = cwd,
		text = true,
		timeout = git_timeout,
		stdout = function(_, data)
			handle_chunk(data)
		end,
		stderr = function(_, data)
			handle_chunk(data)
		end,
	}, function(res)
		vim.schedule(function()
			if line_buffer ~= "" then
				safe_append(plugin, line_buffer)
				line_buffer = ""
			end
			local combined_out = table.concat(accumulated)
			on_done(res.code, combined_out)
		end)
	end)
	if not ok then
		safe_append(plugin, "failed to spawn git: " .. tostring(err))
		vim.schedule(function()
			on_done(-1, "")
		end)
	end
end

function M.parse_behind_count(output)
	if type(output) ~= "string" then
		return nil
	end
	local digits = output:match("^%s*(%d+)%s*$")
	return digits and tonumber(digits) or nil
end

function M.parse_revision_pair(output)
	if type(output) ~= "string" then
		return nil, nil
	end
	local lines = {}
	for line in output:gmatch("([^\r\n]+)") do
		table.insert(lines, line)
	end
	return lines[1], lines[2]
end

function M.parse_upstream_branch_name(output)
	if type(output) ~= "string" then
		return nil
	end
	local trimmed = vim.trim(output)
	if trimmed == "" then
		return nil
	end
	return trimmed:match("^[^/]-/(.+)$") or trimmed
end

function M.parse_pending_commits(output)
	if type(output) ~= "string" or output == "" then
		return {}
	end
	return vim.iter(output:gmatch("([^\r\n]+)")):totable()
end

function M.upstream_ref(plugin, dir, git_fn, cb)
	if plugin.branch then
		return cb("origin/" .. plugin.branch)
	end
	if plugin.tag or plugin.commit or plugin.version or plugin.sem_version then
		return cb(nil)
	end
	git_fn(plugin, { "symbolic-ref", "--short", "refs/remotes/origin/HEAD" }, dir, function(code, out)
		if code == 0 then
			local ref = vim.trim(out or "")
			if ref ~= "" then
				return cb(ref)
			end
		end
		cb(nil)
	end)
end

return M
