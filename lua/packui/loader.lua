local state = require("packui.state")

local M = {}

local function packadd(name)
  local ok, err = pcall(vim.cmd, "packadd " .. name)
  if not ok then
    vim.notify("Error loading plugin " .. name .. ": " .. tostring(err), vim.log.levels.ERROR)
  end
  return ok
end

-- Accepts: "<lhs>" | { "<lhs>", mode=... } | { "<lhs>", rhs, mode=..., desc=..., ... }
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
        if type(key) == "string" and key ~= "mode" then
          opts[key] = value
        end
      end
      table.insert(entries, { lhs = k[1] or k.lhs, rhs = k[2], modes = modes, opts = opts })
    end
  end
  return entries
end

-- Entries with an explicit rhs are mapped directly (mirrors packui.map_keys).
-- Bare-lhs entries only make sense on a lazy plugin: pressing the key loads
-- the plugin then replays the keypress so the plugin's own mapping fires.
local function setup_keys(p)
  for _, entry in ipairs(normalize_key_entries(p.keys)) do
    local lhs = entry.lhs
    if not p.lazy then
      if entry.rhs == nil then
        vim.notify(
          "packui: '" .. p.name .. "' keys entry '" .. lhs .. "' has no rhs and the plugin isn't lazy - nothing to bind",
          vim.log.levels.WARN
        )
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
        M.load(p.name)
        local replay = function()
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(lhs, true, true, true), "m", false)
        end
        if entry.rhs == nil then
          -- rely on the plugin's own config() to have (re)defined this mapping
          replay()
        elseif type(entry.rhs) == "function" then
          for _, mode in ipairs(entry.modes) do
            vim.keymap.set(mode, lhs, entry.rhs, entry.opts)
          end
          entry.rhs()
        else
          for _, mode in ipairs(entry.modes) do
            vim.keymap.set(mode, lhs, entry.rhs, entry.opts)
          end
          replay()
        end
      end
      local trigger_opts = vim.tbl_extend("force", { desc = "packui: lazy-load " .. p.name }, entry.opts)
      for _, mode in ipairs(entry.modes) do
        vim.keymap.set(mode, lhs, trigger, trigger_opts)
      end
    end
  end
end

function M.init(config)
  -- :packadd resolves <packpath-entry>/pack/*/opt|start/<name>, and our plugin
  -- dirs live at install_path/opt|start/<name>, so the packpath entry must be
  -- install_path's grandparent (install_path itself must end in "pack/<name>").
  local packpath_root = vim.fn.fnamemodify(config.install_path, ":h:h")
  if vim.fn.fnamemodify(config.install_path, ":h:t") ~= "pack" then
    vim.notify(
      "packui: install_path '" .. config.install_path .. "' should end in 'pack/<name>' for :packadd to find plugins",
      vim.log.levels.WARN
    )
  end
  vim.opt.packpath:prepend(packpath_root)

  local plugins = state.get_plugins()
  local seen_cmds = {}

  for _, p in pairs(plugins) do
    if p.lazy and p.status == "installed" then
      if p.cmd then
        local cmds = type(p.cmd) == "table" and p.cmd or { p.cmd }
        for _, cmd in ipairs(cmds) do
          if seen_cmds[cmd] then
            vim.notify(
              "packui: command '" .. cmd .. "' already registered by " .. seen_cmds[cmd] .. ", overwriting for " .. p.name,
              vim.log.levels.WARN
            )
          end
          seen_cmds[cmd] = p.name
          vim.api.nvim_create_user_command(cmd, function(args)
            vim.api.nvim_del_user_command(cmd)
            M.load(p.name)
            local cmd_str = cmd
            if args.args and args.args ~= "" then
              cmd_str = cmd_str .. " " .. args.args
            end
            if args.bang then
              cmd_str = cmd_str .. "!"
            end
            pcall(vim.cmd, cmd_str)
          end, { nargs = "*", bang = true, complete = "file" })
        end
      end
      
      -- Source ftdetect files for lazy plugins
      local ftdetect_vim = vim.fn.globpath(p.dir, "ftdetect/*.vim", true, true)
      local ftdetect_lua = vim.fn.globpath(p.dir, "ftdetect/*.lua", true, true)
      for _, file in ipairs(ftdetect_vim) do
        local ok, err = pcall(vim.cmd, "source " .. vim.fn.fnameescape(file))
        if not ok then
          vim.notify("Error sourcing " .. file .. ": " .. tostring(err), vim.log.levels.ERROR)
        end
      end
      for _, file in ipairs(ftdetect_lua) do
        local ok, err = pcall(vim.cmd, "source " .. vim.fn.fnameescape(file))
        if not ok then
          vim.notify("Error sourcing " .. file .. ": " .. tostring(err), vim.log.levels.ERROR)
        end
      end
      
      if p.event then
        local events = type(p.event) == "table" and p.event or { p.event }
        for _, event in ipairs(events) do
          vim.api.nvim_create_autocmd(event, {
            once = true,
            callback = function()
              M.load(p.name)
            end,
          })
        end
      end

      if p.ft then
        local fts = type(p.ft) == "table" and p.ft or { p.ft }
        vim.api.nvim_create_autocmd("FileType", {
          pattern = fts,
          once = true,
          callback = function()
            M.load(p.name)
          end,
        })
      end

    elseif not p.lazy and p.status == "installed" then
      if packadd(p.name) then
        state.update_status(p.name, "loaded")
        if p.config then
          vim.schedule(function()
            local ok, err = pcall(p.config)
            if not ok then
              vim.notify("Error loading config for " .. p.name .. ": " .. tostring(err), vim.log.levels.ERROR)
            end
          end)
        end
      end
    end

    if p.keys and (p.status == "installed" or p.status == "loaded") then
      setup_keys(p)
    end
  end
end

function M.load(name)
  local plugins = state.get_plugins()
  local p = plugins[name]
  if not p or p.status == "loaded" then return end

  if packadd(name) then
    state.update_status(name, "loaded")

    if p.config then
      local ok, err = pcall(p.config)
      if not ok then
        vim.notify("Error loading config for " .. name .. ": " .. tostring(err), vim.log.levels.ERROR)
      end
    end
  end

  if package.loaded["packui.ui"] then
    require("packui.ui").update()
  end
end

return M
