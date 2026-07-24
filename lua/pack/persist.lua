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

  -- Let vim.json handle escaping; the previous hand-rolled writer produced
  -- invalid JSON for any name/value containing a quote, backslash or newline.
  local encode_ok, encoded = pcall(vim.json.encode, data)
  if not encode_ok then
    vim.notify("pack: failed to encode " .. M.path(), vim.log.levels.ERROR)
    return false
  end

  local write_ok = pcall(vim.fn.writefile, { encoded }, M.path())
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
