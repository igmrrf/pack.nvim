local M = {}

local lockfile_path = nil

function M.init(config)
  lockfile_path = config.lockfile_path
end

function M._set_path_for_testing(path)
  lockfile_path = path
end

function M.load()
  if not lockfile_path then return {} end
  if vim.fn.filereadable(lockfile_path) == 0 then return {} end

  local lines = vim.fn.readfile(lockfile_path)
  if not lines or #lines == 0 then return {} end

  local content = table.concat(lines, "\n")
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then
    vim.notify("packui: " .. lockfile_path .. " is not valid JSON, ignoring", vim.log.levels.WARN)
    return {}
  end
  return data
end

function M.save(data)
  if not lockfile_path then return end
  
  local plugins = data.plugins or {}
  local names = vim.tbl_keys(plugins)
  table.sort(names)
  
  local lines = { "{", '  "plugins": {' }
  for i, name in ipairs(names) do
    local p = plugins[name]
    if p and p.rev then
      table.insert(lines, string.format('    "%s": {', name))
      table.insert(lines, string.format('      "rev": "%s"%s', p.rev, p.src and "," or ""))
      if p.src then
        table.insert(lines, string.format('      "src": "%s"', p.src))
      end
      table.insert(lines, string.format('    }%s', i < #names and "," or ""))
    end
  end
  table.insert(lines, "  }")
  table.insert(lines, "}")
  
  vim.fn.writefile(lines, lockfile_path)
end

function M.get_commit(name)
  local data = M.load()
  local plugins = data.plugins or {}
  local p = plugins[name]
  if p then
    return p.rev
  end
  return nil
end

function M.set_commit(name, commit, src)
  local data = M.load()
  if not data.plugins then data.plugins = {} end
  if not data.plugins[name] then data.plugins[name] = {} end
  data.plugins[name].rev = commit
  if src then
    data.plugins[name].src = src
  end
  M.save(data)
end

return M
