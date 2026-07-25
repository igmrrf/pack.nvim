local persist = require("pack.persist")

-- End-to-end check that all three plugin-provenance styles are tracked
-- correctly together after a single pack.setup() call:
--   1. declarative spec (passed via opts.plugins)              -> managed = true
--   2. imperative vim.pack.add through the wrapper, called     -> managed = true
--      AFTER setup() has already returned
--   3. a plugin native vim.pack.get() reports but that was     -> managed = false
--      never declared to pack.nvim (adopted)
--
-- This is complementary to the regression coverage in tests/delegate_spec.lua:
-- that file has separate tests for (a) adoption-during-setup and (b) an
-- imperative vim.pack.add call that fires DURING load_plugins/import (i.e.
-- before setup() returns). This test instead exercises all three provenance
-- styles together, including a wrapper call made strictly AFTER setup()
-- returns, in one config.
describe("pack.nvim dual-style plugin tracking (end-to-end)", function()
  local tmp_path, orig_vim_pack

  before_each(function()
    tmp_path = vim.fn.tempname() .. "-pack-disabled.json"
    persist._set_path_for_testing(tmp_path)
    orig_vim_pack = vim.pack
  end)

  after_each(function()
    vim.pack = orig_vim_pack
    if vim.fn.filereadable(tmp_path) == 1 then vim.fn.delete(tmp_path) end
    persist._set_path_for_testing(nil)
  end)

  it("tracks declarative, wrapped-imperative, and adopted plugins together", function()
    local pack = require("pack")
    local state = require("pack.state")
    local added = {}
    vim.pack = {
      add = function(specs) for _, s in ipairs(specs) do added[s.name] = true end end,
      get = function()
        return { { spec = { name = "adopted.nvim", src = "https://github.com/x/adopted.nvim" }, path = "/x/adopted.nvim" } }
      end,
      del = function() end,
      update = function() end,
    }

    pack.setup({ plugins = { { "folke/flash.nvim" } } })
    -- imperative call after setup routes through the wrapper -> managed
    vim.pack.add({ { src = "https://github.com/user/imp.nvim", name = "imp.nvim" } })

    local plugins = state.get_plugins()
    assert.is_true(plugins["flash.nvim"].managed) -- declarative
    assert.is_true(plugins["imp.nvim"].managed) -- wrapped imperative
    assert.is_false(plugins["adopted.nvim"].managed) -- native-only, adopted
  end)
end)
