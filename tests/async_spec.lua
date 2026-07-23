local async = require("packui.async")

describe("packui.async.parse_behind_count", function()
  it("parses a well-formed count with trailing newline", function()
    assert.equals(3, async.parse_behind_count("3\n"))
  end)

  it("parses zero", function()
    assert.equals(0, async.parse_behind_count("0"))
  end)

  it("returns nil for empty output", function()
    assert.is_nil(async.parse_behind_count(""))
  end)

  it("returns nil for garbage/error output", function()
    assert.is_nil(async.parse_behind_count("fatal: no upstream configured for branch"))
  end)

  it("returns nil for non-string input", function()
    assert.is_nil(async.parse_behind_count(nil))
  end)
end)
