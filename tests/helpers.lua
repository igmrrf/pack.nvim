local pack = require("pack")
local state = require("pack.state")
local loader = require("pack.loader")
local persist = require("pack.persist")

local M = {}

function M.reset()
  pack.native_pack = vim.pack
  pack._real_native = nil
  state.init({ plugins = {} })
  if state._set_native_opt_dir_for_testing then
    state._set_native_opt_dir_for_testing(vim.fn.tempname() .. "-site-pack-opt")
  end
  if loader._reset_for_testing then
    loader._reset_for_testing()
  end
  persist._set_path_for_testing(vim.fn.tempname())
  -- Isolate the ftdetect precompile cache per test: build_cache writes a shared
  -- stdpath('data') path otherwise, so a flush_pending in one test can overwrite
  -- the file another test is asserting on (intermittent flake).
  if loader._set_ftdetect_cache_path_for_testing then
    loader._set_ftdetect_cache_path_for_testing(vim.fn.tempname())
  end
end

return M
