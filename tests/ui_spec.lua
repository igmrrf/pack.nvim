local ui = require("packui.ui")
local state = require("packui.state")
local persist = require("packui.persist")

local function config_with(plugins)
  return {
    install_path = vim.fn.tempname() .. "-packui-install",
    ui = {
      border = "rounded",
      icons = { loaded = "*", not_loaded = "o", error = "x", sync = "~" },
    },
    plugins = plugins,
  }
end

local function find_line(buf, pattern)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, line in ipairs(lines) do
    if line:match(pattern) then
      return i
    end
  end
  error("pattern not found in buffer: " .. pattern)
end

local function close_all_but_one_window()
  local max_attempts = 20
  local attempts = 0
  while #vim.api.nvim_list_wins() > 1 and attempts < max_attempts do
    pcall(vim.api.nvim_win_close, 0, true)
    attempts = attempts + 1
  end
  assert.equals(1, #vim.api.nvim_list_wins())
end

describe("packui.ui", function()
  local tmp_path

  before_each(function()
    tmp_path = vim.fn.tempname() .. "-disabled.json"
    persist._set_path_for_testing(tmp_path)
  end)

  after_each(function()
    close_all_but_one_window()
    if vim.fn.filereadable(tmp_path) == 1 then
      vim.fn.delete(tmp_path)
    end
    persist._set_path_for_testing(nil)
  end)

  describe("help popup", function()
    it("opens a popup listing keymaps", function()
      local config = config_with({ "user/foo.nvim" })
      state.init(config)
      ui.open(config)
      ui.show_help()
      local buf = vim.api.nvim_get_current_buf()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local text = table.concat(lines, "\n")
      assert.is_true(text:match("Packui Keymaps") ~= nil)
      assert.is_true(text:match("close") ~= nil)
    end)

    it("wires '?' to open the help popup", function()
      local config = config_with({ "user/foo.nvim" })
      state.init(config)
      ui.open(config)
      local dashboard_buf = vim.api.nvim_get_current_buf()

      -- Verify the keymap exists and is buffer-local
      local mapping = vim.fn.maparg("?", "n", false, true)
      assert.is_not_nil(mapping)
      assert.is_true(mapping.buffer == 1)

      -- Trigger the keymap and verify it opens the help popup
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("?", true, false, true), "mtx", false)
      local popup_buf = vim.api.nvim_get_current_buf()
      assert.are_not_equal(dashboard_buf, popup_buf)

      -- Verify help content is displayed
      local lines = vim.api.nvim_buf_get_lines(popup_buf, 0, -1, false)
      local text = table.concat(lines, "\n")
      assert.is_true(text:match("Packui Keymaps") ~= nil)
    end)
  end)

  describe("details popups", function()
    it("show_details opens a popup naming the plugin under cursor", function()
      local config = config_with({ "user/foo.nvim" })
      state.init(config)
      ui.open(config)
      local buf = vim.api.nvim_get_current_buf()
      local line = find_line(buf, "foo%.nvim")
      vim.api.nvim_win_set_cursor(0, { line, 0 })

      ui.show_details()
      local popup_buf = vim.api.nvim_get_current_buf()
      local lines = vim.api.nvim_buf_get_lines(popup_buf, 0, -1, false)
      assert.is_true(vim.tbl_contains(lines, "  foo.nvim"))
    end)

    it("show_full_details reports no commit info for a non-git directory", function()
      local config = config_with({ "user/foo.nvim" })
      state.init(config)
      ui.open(config)
      local buf = vim.api.nvim_get_current_buf()
      local line = find_line(buf, "foo%.nvim")
      vim.api.nvim_win_set_cursor(0, { line, 0 })

      ui.show_full_details()
      local popup_buf = vim.api.nvim_get_current_buf()
      local lines = vim.api.nvim_buf_get_lines(popup_buf, 0, -1, false)
      local found = false
      for _, l in ipairs(lines) do
        if l:match("no commit info available") then
          found = true
        end
      end
      assert.is_true(found)
    end)
  end)
end)
