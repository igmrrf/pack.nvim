local state = require("pack.state")
local loader = require("pack.loader")
local persist = require("pack.persist")

local M = {}

function M.reset()
  state.init({ plugins = {} })
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
