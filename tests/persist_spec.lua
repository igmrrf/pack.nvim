local persist = require("packui.persist")

describe("packui.persist", function()
  local tmp_path

  before_each(function()
    tmp_path = vim.fn.tempname() .. "-packui-disabled.json"
    persist._set_path_for_testing(tmp_path)
  end)

  after_each(function()
    if vim.fn.filereadable(tmp_path) == 1 then
      vim.fn.delete(tmp_path)
    end
    persist._set_path_for_testing(nil)
  end)

  it("returns an empty set when the file does not exist", function()
    assert.same({}, persist.load())
  end)

  it("round-trips a saved set", function()
    persist.save({ ["foo.nvim"] = true, ["bar.nvim"] = true })
    local set = persist.load()
    assert.is_true(set["foo.nvim"])
    assert.is_true(set["bar.nvim"])
    assert.is_nil(set["baz.nvim"])
  end)

  it("returns an empty set on corrupt json", function()
    vim.fn.writefile({ "{not valid json" }, tmp_path)
    assert.same({}, persist.load())
  end)

  it("returns an empty set when json is an object instead of array", function()
    vim.fn.writefile({ '{"foo.nvim": true}' }, tmp_path)
    assert.same({}, persist.load())
  end)

  it("set_disabled adds and removes membership, persisting each time", function()
    persist.set_disabled("foo.nvim", true)
    assert.is_true(persist.load()["foo.nvim"])

    persist.set_disabled("foo.nvim", false)
    assert.is_nil(persist.load()["foo.nvim"])
  end)
end)
