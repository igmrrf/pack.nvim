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
end

return M
