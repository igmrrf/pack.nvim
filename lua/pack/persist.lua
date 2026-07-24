local M = {}

local override_path = nil

function M.path()
  return override_path or (vim.fn.stdpath("config") .. "/nvim-pack-extra.json")
end

function M._set_path_for_testing(path)
  override_path = path
end

function M._load_raw()
  local path = M.path()
  if vim.fn.filereadable(path) == 0 then
    return {}
  end

  local read_ok, lines = pcall(vim.fn.readfile, path)
  if not read_ok then
    vim.notify("pack: failed to read " .. path, vim.log.levels.WARN)
    return {}
  end

  local decode_ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decode_ok or type(decoded) ~= "table" then
    vim.notify("pack: " .. path .. " is not valid JSON, ignoring", vim.log.levels.WARN)
    return {}
  end

  return decoded
end

function M.load()
  local data = M._load_raw()
  local set = {}
  if data.plugins then
    for name, opts in pairs(data.plugins) do
      if type(opts) == "table" and opts.disabled then
        set[name] = true
      end
    end
  end
  return set
end

function M.save(set)
  local data = M._load_raw()
  if not data.plugins then data.plugins = {} end
  
  for _, opts in pairs(data.plugins) do
    if type(opts) == "table" then
      opts.disabled = nil
    end
  end
  
  for name in pairs(set) do
    if not data.plugins[name] then data.plugins[name] = {} end
    data.plugins[name].disabled = true
  end

  for name, opts in pairs(data.plugins) do
    if vim.tbl_isempty(opts) then
      data.plugins[name] = nil
    end
  end

  local lines = { "{", '  "plugins": {' }
  local names = vim.tbl_keys(data.plugins)
  table.sort(names)
  
  for i, name in ipairs(names) do
    local opts = data.plugins[name]
    table.insert(lines, string.format('    "%s": {', name))
    
    local opt_keys = vim.tbl_keys(opts)
    table.sort(opt_keys)
    
    for j, k in ipairs(opt_keys) do
      local v = opts[k]
      local val_str = type(v) == "boolean" and tostring(v) or string.format('"%s"', v)
      table.insert(lines, string.format('      "%s": %s%s', k, val_str, j < #opt_keys and "," or ""))
    end
    
    table.insert(lines, string.format('    }%s', i < #names and "," or ""))
  end
  table.insert(lines, "  }")
  table.insert(lines, "}")

  local write_ok = pcall(vim.fn.writefile, lines, M.path())
  if not write_ok then
    vim.notify("pack: failed to write " .. M.path(), vim.log.levels.ERROR)
    return false
  end
  return true
end

function M.set_disabled(name, disabled)
  local set = M.load()
  if disabled then
    set[name] = true
  else
    set[name] = nil
  end
  M.save(set)
  return set
end

return M
