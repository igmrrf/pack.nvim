local state = require("packui.state")

local M = {}

function M.init(config)
  vim.opt.packpath:prepend(config.install_path)
  
  local plugins = state.get_plugins()
  
  for _, p in pairs(plugins) do
    if p.lazy and p.status == "installed" then
      if p.cmd then
        local cmds = type(p.cmd) == "table" and p.cmd or { p.cmd }
        for _, cmd in ipairs(cmds) do
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
      for _, file in ipairs(ftdetect_vim) do vim.cmd("source " .. file) end
      for _, file in ipairs(ftdetect_lua) do vim.cmd("source " .. file) end
      
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
      vim.cmd("packadd " .. p.name)
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
end

function M.load(name)
  local plugins = state.get_plugins()
  local p = plugins[name]
  if not p or p.status == "loaded" then return end
  
  vim.cmd("packadd " .. name)
  state.update_status(name, "loaded")
  
  if p.config then
    local ok, err = pcall(p.config)
    if not ok then
      vim.notify("Error loading config for " .. name .. ": " .. tostring(err), vim.log.levels.ERROR)
    end
  end
  
  if package.loaded["packui.ui"] then
    require("packui.ui").update()
  end
end

return M
