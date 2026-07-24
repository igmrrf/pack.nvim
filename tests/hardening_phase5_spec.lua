local state = require("pack.state")
local loader = require("pack.loader")

describe("pack :checkhealth (5)", function()
  it("runs and reports vim.pack + plugin status without error", function()
    state.init({ plugins = { "u/foo.nvim" } })
    local ok = pcall(vim.cmd, "checkhealth pack")
    assert.is_true(ok, "checkhealth pack must not error")

    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local joined = table.concat(lines, "\n")
    assert.is_true(joined:find("pack.nvim", 1, true) ~= nil, "report mentions pack.nvim")
    assert.is_true(joined:find("vim.pack", 1, true) ~= nil, "report checks vim.pack")
  end)
end)

describe("pack helptags generation (5)", function()
  it("generates a doc/tags file when a plugin with docs is loaded", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/plugin", "p")
    vim.fn.writefile({ "_G.PACK_HELP_LOADED = true" }, dir .. "/plugin/init.lua")
    vim.fn.mkdir(dir .. "/doc", "p")
    vim.fn.writefile({ "*mypluginhelp*  My Plugin", "", "Some help text." }, dir .. "/doc/myplugin.txt")
    _G.PACK_HELP_LOADED = nil

    state.init({ plugins = { { "helpplug", dir = dir } } })
    loader.load("helpplug")

    assert.is_true(_G.PACK_HELP_LOADED, "sanity: plugin actually loaded")
    assert.equals(1, vim.fn.filereadable(dir .. "/doc/tags"), "helptags must be generated on load")
    _G.PACK_HELP_LOADED = nil
  end)
end)
