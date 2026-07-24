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
    it("toggle_details expands details inline", function()
      local config = config_with({ "user/foo.nvim" })
      state.init(config)
      ui.open(config)
      local buf = vim.api.nvim_get_current_buf()
      local line = find_line(buf, "foo%.nvim")
      vim.api.nvim_win_set_cursor(0, { line, 0 })

      ui.toggle_details()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local text = table.concat(lines, "\n")
      assert.is_true(text:match("url:      ") ~= nil)
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

  describe("tabs", function()
    it("excludes disabled plugins from the All tab and lists them in Disabled", function()
      local config = config_with({ "user/foo.nvim", "user/bar.nvim" })
      state.init(config)
      state.set_disabled("bar.nvim", true)
      ui.open(config)

      local all_buf = vim.api.nvim_get_current_buf()
      local all_lines = vim.api.nvim_buf_get_lines(all_buf, 0, -1, false)
      local all_text = table.concat(all_lines, "\n")
      assert.is_true(all_text:match("foo%.nvim") ~= nil)
      assert.is_nil(all_text:match("bar%.nvim"))

      ui.cycle_tab() -- all -> outdated
      ui.cycle_tab() -- outdated -> disabled
      local disabled_buf = vim.api.nvim_get_current_buf()
      local disabled_lines = vim.api.nvim_buf_get_lines(disabled_buf, 0, -1, false)
      local disabled_text = table.concat(disabled_lines, "\n")
      assert.is_true(disabled_text:match("bar%.nvim") ~= nil)
    end)

    it("Outdated tab only lists plugins with behind > 0", function()
      local config = config_with({ "user/foo.nvim", "user/bar.nvim" })
      state.init(config)
      state.set_behind("foo.nvim", 2)
      ui.open(config)

      ui.cycle_tab() -- all -> outdated
      local buf = vim.api.nvim_get_current_buf()
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      assert.is_true(text:match("foo%.nvim") ~= nil)
      assert.is_nil(text:match("bar%.nvim"))
    end)

    it("cycling from Disabled returns to All", function()
      local config = config_with({ "user/foo.nvim" })
      state.init(config)
      ui.open(config)
      ui.cycle_tab() -- all -> outdated
      ui.cycle_tab() -- outdated -> disabled
      ui.cycle_tab() -- disabled -> all
      local buf = vim.api.nvim_get_current_buf()
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      assert.is_true(text:match("foo%.nvim") ~= nil)
    end)
  end)

  describe("disable/enable toggle", function()
    it("disabling a not-yet-loaded plugin moves it to the Disabled tab and persists", function()
      local config = config_with({ "user/foo.nvim" })
      state.init(config)
      ui.open(config)
      local buf = vim.api.nvim_get_current_buf()
      local line = find_line(buf, "foo%.nvim")
      vim.api.nvim_win_set_cursor(0, { line, 0 })

      ui.toggle_disabled()

      assert.is_true(state.get_plugins()["foo.nvim"].disabled)
      assert.is_true(require("packui.persist").load()["foo.nvim"])

      ui.cycle_tab() -- all -> outdated
      ui.cycle_tab() -- outdated -> disabled
      local disabled_buf = vim.api.nvim_get_current_buf()
      local text = table.concat(vim.api.nvim_buf_get_lines(disabled_buf, 0, -1, false), "\n")
      assert.is_true(text:match("foo%.nvim") ~= nil)
    end)

    it("re-enabling from the Disabled tab clears the flag", function()
      local config = config_with({ "user/foo.nvim" })
      state.init(config)
      state.set_disabled("foo.nvim", true)
      ui.open(config)
      ui.cycle_tab() -- all -> outdated
      ui.cycle_tab() -- outdated -> disabled
      local buf = vim.api.nvim_get_current_buf()
      local line = find_line(buf, "foo%.nvim")
      vim.api.nvim_win_set_cursor(0, { line, 0 })

      ui.toggle_disabled()

      assert.is_false(state.get_plugins()["foo.nvim"].disabled)
      assert.is_nil(require("packui.persist").load()["foo.nvim"])
    end)

    it("disabling an already-loaded plugin warns but does not error", function()
      local config = config_with({ "user/foo.nvim" })
      state.init(config)
      state.update_status("foo.nvim", "loaded")
      ui.open(config)
      local buf = vim.api.nvim_get_current_buf()
      local line = find_line(buf, "foo%.nvim")
      vim.api.nvim_win_set_cursor(0, { line, 0 })

      local ok = pcall(ui.toggle_disabled)

      assert.is_true(ok)
      assert.is_true(state.get_plugins()["foo.nvim"].disabled)
    end)

    it("a bare-lhs keys mapping on an already-loaded lazy plugin survives a disable->enable cycle", function()
      -- Regression test: an already-loaded plugin's real, live keymap (bound
      -- by the plugin's own config()) must never be torn down/rebuilt by
      -- toggling disable/enable - there is nothing safe to restore for it.
      local config = config_with({ { "user/foo.nvim", lazy = true, keys = "<leader>zz" } })
      state.init(config)
      state.update_status("foo.nvim", "loaded")
      -- Simulate the plugin's own config() having already (re)defined lhs
      -- for real, as would happen once the plugin finished loading.
      vim.keymap.set("n", "<leader>zz", function() end, { desc = "fixture: foo.nvim real mapping" })
      assert.is_true(vim.fn.maparg("<leader>zz", "n") ~= "")

      ui.open(config)
      local buf = vim.api.nvim_get_current_buf()
      local line = find_line(buf, "foo%.nvim")
      vim.api.nvim_win_set_cursor(0, { line, 0 })

      ui.toggle_disabled() -- disable
      assert.is_true(state.get_plugins()["foo.nvim"].disabled)
      assert.is_true(vim.fn.maparg("<leader>zz", "n") ~= "", "keymap must survive disabling an already-loaded plugin")

      -- foo.nvim no longer appears in the All tab once disabled - jump to
      -- the Disabled tab to find it under the cursor again before re-enabling.
      ui.cycle_tab() -- all -> outdated
      ui.cycle_tab() -- outdated -> disabled
      local disabled_buf = vim.api.nvim_get_current_buf()
      local disabled_line = find_line(disabled_buf, "foo%.nvim")
      vim.api.nvim_win_set_cursor(0, { disabled_line, 0 })

      ui.toggle_disabled() -- re-enable
      assert.is_false(state.get_plugins()["foo.nvim"].disabled)
      assert.is_true(vim.fn.maparg("<leader>zz", "n") ~= "", "keymap must survive re-enabling an already-loaded plugin")

      pcall(vim.keymap.del, "n", "<leader>zz")
    end)
  end)

  describe("outdated tab rich display", function()
    it("renders path/source/revision/pending-commits for a plugin with full outdated detail", function()
      local config = config_with({ "user/foo.nvim" })
      state.init(config)
      state.set_behind("foo.nvim", 2)
      state.set_outdated_detail("foo.nvim", {
        revision_before = "e068ab5",
        revision_after = "c7c692a",
        upstream_branch = "main",
        pending_commits = { "c7c692a │ fix: something (#1023)", "058e83d │ fix!: other thing (#1019)" },
      })
      ui.open(config)
      ui.cycle_tab() -- all -> outdated
      local buf = vim.api.nvim_get_current_buf()
      local line = find_line(buf, "foo%.nvim")
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      ui.toggle_details()
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      if text:match("Path:") == nil then error("Failed to find Path:. Text was: \n" .. text) end
      assert.is_true(text:match("Path:") ~= nil)
      assert.is_true(text:match("Source:") ~= nil)
      assert.is_true(text:match("Revision before:%s+e068ab5") ~= nil)
      assert.is_true(text:match("Revision after:%s+c7c692a %(main%)") ~= nil)
      assert.is_true(text:match("c7c692a │ fix: something %(#1023%)") ~= nil)
      assert.is_true(text:match("058e83d │ fix!: other thing %(#1019%)") ~= nil)
    end)

    it("falls back to a compact line when pending_commits hasn't been populated yet", function()
      local config = config_with({ "user/foo.nvim" })
      state.init(config)
      state.set_behind("foo.nvim", 3)
      ui.open(config)
      ui.cycle_tab() -- all -> outdated
      local buf = vim.api.nvim_get_current_buf()
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      assert.is_true(text:match("foo%.nvim") ~= nil)
      assert.is_true(text:match("3 behind") ~= nil)
      assert.is_nil(text:match("Pending updates:"))
    end)

    it("maps every line of a plugin's rich block to that plugin for u/K/Enter", function()
      local config = config_with({ "user/foo.nvim" })
      state.init(config)
      state.set_behind("foo.nvim", 1)
      state.set_outdated_detail("foo.nvim", {
        revision_before = "aaa1111",
        revision_after = "bbb2222",
        upstream_branch = "main",
        pending_commits = { "bbb2222 │ fix: x" },
      })
      ui.open(config)
      ui.cycle_tab() -- all -> outdated
      local buf = vim.api.nvim_get_current_buf()
      local line = find_line(buf, "foo%.nvim")
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      ui.toggle_details()
      line = find_line(buf, "Pending updates:")
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      ui.show_full_details()
      local popup_buf = vim.api.nvim_get_current_buf()
      local popup_text = table.concat(vim.api.nvim_buf_get_lines(popup_buf, 0, -1, false), "\n")
      assert.is_true(popup_text:match("foo%.nvim") ~= nil)
    end)
  end)

  describe("outdated updates", function()
    it("update_one calls async.update_plugin for the cursor plugin while on the Outdated tab", function()
      local config = config_with({ "user/foo.nvim" })
      state.init(config)
      state.set_behind("foo.nvim", 3)
      ui.open(config)
      ui.cycle_tab() -- all -> outdated
      local buf = vim.api.nvim_get_current_buf()
      local line = find_line(buf, "foo%.nvim")
      vim.api.nvim_win_set_cursor(0, { line, 0 })

      local async = require("packui.async")
      local called_with = nil
      local original = async.update_plugin
      async.update_plugin = function(p) called_with = p.name end

      ui.update_one()

      async.update_plugin = original
      assert.equals("foo.nvim", called_with)
    end)

    it("update_one is a no-op outside the Outdated tab", function()
      local config = config_with({ "user/foo.nvim" })
      state.init(config)
      state.set_behind("foo.nvim", 3)
      ui.open(config) -- defaults to the All tab
      local buf = vim.api.nvim_get_current_buf()
      local line = find_line(buf, "foo%.nvim")
      vim.api.nvim_win_set_cursor(0, { line, 0 })

      local async = require("packui.async")
      local called = false
      local original = async.update_plugin
      async.update_plugin = function() called = true end

      ui.update_one()

      async.update_plugin = original
      assert.is_false(called)
    end)

    it("update_all_outdated updates every plugin with behind > 0", function()
      local config = config_with({ "user/foo.nvim", "user/bar.nvim" })
      state.init(config)
      state.set_behind("foo.nvim", 3)
      state.set_behind("bar.nvim", 0)
      ui.open(config)
      ui.cycle_tab() -- all -> outdated

      local async = require("packui.async")
      local updated = {}
      local original = async.update_plugin
      async.update_plugin = function(p) table.insert(updated, p.name) end

      ui.update_all_outdated()

      async.update_plugin = original
      assert.same({ "foo.nvim" }, updated)
    end)
  end)
end)
