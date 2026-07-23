local M = {}

local override_path = nil

function M.path()
  return override_path or (vim.fn.stdpath("config") .. "/packui-disabled.json")
end

function M._set_path_for_testing(path)
  override_path = path
end

function M.load()
  local path = M.path()
  if vim.fn.filereadable(path) == 0 then
    return {}
  end

  local read_ok, lines = pcall(vim.fn.readfile, path)
  if not read_ok then
    vim.notify("packui: failed to read " .. path, vim.log.levels.WARN)
    return {}
  end

  local decode_ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decode_ok or type(decoded) ~= "table" or not vim.islist(decoded) then
    vim.notify("packui: " .. path .. " is not valid JSON, ignoring", vim.log.levels.WARN)
    return {}
  end

  local set = {}
  for _, name in ipairs(decoded) do
    if type(name) == "string" then
      set[name] = true
    end
  end
  return set
end

function M.save(set)
  local names = {}
  for name in pairs(set) do
    table.insert(names, name)
  end
  table.sort(names)

  local encode_ok, encoded = pcall(vim.json.encode, names)
  if not encode_ok then
    vim.notify("packui: failed to encode disabled-plugin list", vim.log.levels.ERROR)
    return false
  end

  local write_ok = pcall(vim.fn.writefile, { encoded }, M.path())
  if not write_ok then
    vim.notify("packui: failed to write " .. M.path(), vim.log.levels.ERROR)
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
