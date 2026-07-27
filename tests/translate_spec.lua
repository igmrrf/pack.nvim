local state = require("pack.state")
local persist = require("pack.persist")

describe("pack.state.to_native_spec", function()
  local tmp_path

  before_each(function()
    tmp_path = vim.fn.tempname() .. "-pack-disabled.json"
    persist._set_path_for_testing(tmp_path)
  end)

  after_each(function()
    if vim.fn.filereadable(tmp_path) == 1 then
      vim.fn.delete(tmp_path)
    end
    persist._set_path_for_testing(nil)
  end)

  -- Normalize `spec` through the real pipeline and hand back its native form.
  local function native_of(spec)
    state.init({ install_path = vim.fn.tempname() .. "-pack-install", plugins = { spec } })
    local name
    for n in pairs(state.get_plugins()) do
      name = n
      break
    end
    return state.to_native_spec(state.get_plugins()[name]), name
  end

  it("expands a shorthand and sets src/name, no version", function()
    local ns = native_of("user/foo.nvim")
    assert.equals("https://github.com/user/foo.nvim", ns.src)
    assert.equals("foo.nvim", ns.name)
    assert.is_nil(ns.version)
    assert.is_false(ns.data.lazy)
  end)

  it("maps commit -> version", function()
    local ns = native_of({ "user/foo.nvim", commit = "abc123def" })
    assert.equals("abc123def", ns.version)
  end)

  it("maps tag -> version", function()
    local ns = native_of({ "user/foo.nvim", tag = "v1.2.3" })
    assert.equals("v1.2.3", ns.version)
  end)

  it("maps branch -> version", function()
    local ns = native_of({ "user/foo.nvim", branch = "develop" })
    assert.equals("develop", ns.version)
  end)

  it("prefers commit over tag and branch", function()
    local ns = native_of({ "user/foo.nvim", commit = "deadbeef", tag = "v1", branch = "main" })
    assert.equals("deadbeef", ns.version)
  end)

  it("turns a version range string into a vim.version range object", function()
    local ns = native_of({ "user/foo.nvim", version = ">=1.0.0" })
    assert.equals("table", type(ns.version))
    assert.is_function(ns.version.has)
  end)

  it("passes a pre-built range table through untouched", function()
    local range = vim.version.range("^2.0.0")
    local ns = native_of({ "user/foo.nvim", version = range })
    assert.equals(range, ns.version)
  end)

  it("carries lazy-loading metadata under data", function()
    local ns = native_of({
      "user/foo.nvim",
      lazy = true,
      event = "BufRead",
      ft = { "lua", "vim" },
      cmd = "FooCmd",
      keys = { { "<leader>f", "<cmd>Foo<cr>" } },
      priority = 100,
    })
    assert.is_true(ns.data.lazy)
    assert.equals("BufRead", ns.data.event)
    assert.same({ "lua", "vim" }, ns.data.ft)
    assert.equals("FooCmd", ns.data.cmd)
    assert.equals(100, ns.data.priority)
    assert.is_table(ns.data.keys)
  end)

  it("sanitizes opts and omits functions from data", function()
    local ns = native_of({ "user/foo.nvim", opts = { a = 1 } })
    assert.is_nil(ns.data.config)
    assert.same({ a = 1 }, ns.data.opts)
  end)

  it("strips explicit config functions from data to prevent C conversion errors", function()
    local fn = function() end
    local ns = native_of({ "user/foo.nvim", config = fn })
    assert.is_nil(ns.data.config)
  end)

  it("carries a string build hook and default priority", function()
    local ns = native_of({ "user/foo.nvim", build = "make" })
    assert.equals("make", ns.data.build)
    assert.equals(50, ns.data.priority)
  end)

  it("sanitizes mixed array/hash tables into pure dictionaries to prevent C conversion errors", function()
    state.init({
      install_path = vim.fn.tempname() .. "-pack-install",
      plugins = {
        {
          "user/foo.nvim",
          keys = {
            { "<leader>f", "<cmd>Foo<cr>", desc = "Find file" },
          },
          dependencies = {
            { "user/dep.nvim", lazy = true },
          },
        },
      },
    })
    local ns = state.to_native_spec(state.get_plugins()["foo.nvim"])
    assert.same({ ["1"] = "<leader>f", ["2"] = "<cmd>Foo<cr>", desc = "Find file" }, ns.data.keys[1])
    assert.same({ ["1"] = "user/dep.nvim", lazy = true }, ns.data.dependencies[1])
  end)
end)
