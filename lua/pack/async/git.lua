local M = {}

-- Run a git command asynchronously.
function M.git(plugin, args, cwd, max_log_lines, git_timeout, append_log_fn, on_done)
	append_log_fn(plugin, "$ git " .. table.concat(args, " "))
	local cmd = { "git" }
	for _, a in ipairs(args) do
		cmd[#cmd + 1] = a
	end
	local ok, err = pcall(vim.system, cmd, { cwd = cwd, text = true, timeout = git_timeout }, function(res)
		vim.schedule(function()
			local out = res.stdout or ""
			local combined = out
			if res.stderr and res.stderr ~= "" then
				combined = combined .. "\n" .. res.stderr
			end
			for line in combined:gmatch("[^\r\n]+") do
				append_log_fn(plugin, line)
			end
			on_done(res.code, out)
		end)
	end)
	if not ok then
		append_log_fn(plugin, "failed to spawn git: " .. tostring(err))
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
	local commits = {}
	for line in output:gmatch("([^\r\n]+)") do
		table.insert(commits, line)
	end
	return commits
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
