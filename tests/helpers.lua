local pack = require("pack")
local state = require("pack.state")
local loader = require("pack.loader")
local persist = require("pack.persist")

local M = {}

function M.reset()
  if package.loaded["pack.ui"] then
    pcall(require("pack.ui").close)
  end
  if package.loaded["pack.ui.spinner"] then
    pcall(require("pack.ui.spinner").stop_spinner)
  end

  pack._real_native = nil
  local test_opt_dir = vim.fn.tempname() .. "-site-pack-opt"
  vim.fn.mkdir(test_opt_dir, "p")

  if state._set_native_opt_dir_for_testing then
    state._set_native_opt_dir_for_testing(test_opt_dir)
  end

  local fake_native = {
    add = function(specs, opts)
      for _, s in ipairs(specs) do
        local p_dir = test_opt_dir .. "/" .. s.name
        vim.fn.mkdir(p_dir, "p")
        if opts and opts.load then
          opts.load({ spec = s, path = p_dir })
        end
      end
    end,
    update = function(names, opts) end,
    del = function(names) end,
    get = function() return {} end,
  }
  pack.native_pack = fake_native
  -- pack.setup() reads vim.pack to detect native vim.pack; without this it
  -- would adopt the *real* vim.pack and attempt actual git clones in tests.
  vim.pack = fake_native

  state.init({ plugins = {} })
  if loader._reset_for_testing then
    loader._reset_for_testing()
  end
  persist._set_path_for_testing(vim.fn.tempname())
  if loader._set_ftdetect_cache_path_for_testing then
    loader._set_ftdetect_cache_path_for_testing(vim.fn.tempname())
  end
end

return M
