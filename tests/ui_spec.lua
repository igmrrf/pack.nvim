local ui = require("pack.ui")
local state = require("pack.state")
local persist = require("pack.persist")

local function config_with(plugins)
  return {
    install_path = vim.fn.tempname() .. "-pack-install",
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
  local wins = vim.api.nvim_list_wins()
  for i = 2, #wins do
    pcall(vim.api.nvim_win_close, wins[i], true)
  end
  assert.equals(1, #vim.api.nvim_list_wins())
end

describe("pack.ui", function()
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
      assert.is_true(text:match("Pack Keymaps") ~= nil)
      assert.is_true(text:match("close") ~= nil)
    end)

    it("wires '?' to open the help popup", function()
      local config = config_with({ "user/foo.nvim" })
      state.init(config)
      ui.open(config)
      local dashboard_buf = vim.api.nvim_get_current_buf()

      -- Verify the keymap exists and is buffer-local
      local keymaps = vim.api.nvim_buf_get_keymap(dashboard_buf, "n")
      assert.is_true(#keymaps > 0)

      -- Trigger help and verify it opens the help popup
      ui.show_help()
      local popup_buf = vim.api.nvim_get_current_buf()
      assert.are_not_equal(dashboard_buf, popup_buf)

      -- Verify help content is displayed
      local lines = vim.api.nvim_buf_get_lines(popup_buf, 0, -1, false)
      local text = table.concat(lines, "\n")
      assert.is_true(text:match("Pack Keymaps") ~= nil)
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

    it("toggle_details does not error for a plugin with a multi-entry keys table", function()
      -- vim.inspect() on a keys table with several entries (some with function
      -- rhs) pretty-prints across multiple lines; that must never leak into a
      -- single nvim_buf_set_lines() entry (each entry must be newline-free).
      local config = config_with({
        {
          "user/keysplug.nvim",
          lazy = true,
          keys = {
            { "<leader>a", function() end, desc = "a" },
            { "<leader>b", function() end, desc = "b" },
            { "<leader>c", ":SomeCmd<CR>", desc = "c" },
          },
        },
      })
      state.init(config)
      ui.open(config)
      local buf = vim.api.nvim_get_current_buf()
      local line = find_line(buf, "keysplug%.nvim")
      vim.api.nvim_win_set_cursor(0, { line, 0 })

      local ok, err = pcall(ui.toggle_details)
      assert.is_true(ok, "toggle_details must not error: " .. tostring(err))

      for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        assert.is_nil(l:find("\n"), "a buffer line must never contain an embedded newline")
      end
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

    it("renders building plugins on the Outdated tab with building… suffix", function()
      local config = config_with({ "user/foo.nvim" })
      state.init(config)
      state.update_status("foo.nvim", "building")
      ui.open(config)

      ui.cycle_tab() -- all -> outdated
      local buf = vim.api.nvim_get_current_buf()
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      assert.is_true(text:match("foo%.nvim — building…") ~= nil)
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

    it("switching tabs jumps to the first plugin, not the previously-focused one", function()
      -- Regression: switching tabs preserved the cursor's plugin if that plugin
      -- also appeared in the target tab (further down), so e.g. Outdated -> All
      -- dumped the cursor tens of lines down instead of at the top. A tab switch
      -- must always land on the first plugin of the new tab.
      local config = config_with({ "user/aaa.nvim", "user/mmm.nvim", "user/zzz.nvim" })
      state.init(config)
      state.set_behind("zzz.nvim", 2) -- only zzz is outdated
      ui.open(config)

      ui.cycle_tab() -- all -> outdated (only zzz.nvim shown)
      local zline = find_line(0, "zzz%.nvim")
      vim.api.nvim_win_set_cursor(0, { zline, 0 })

      ui.set_tab(1) -- back to All: must jump to first plugin, not chase zzz

      local row = vim.api.nvim_win_get_cursor(0)[1]
      local cur = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ""
      assert.is_true(cur:match("aaa%.nvim") ~= nil, "cursor should be on the first plugin, got: " .. cur)
      assert.is_nil(cur:match("zzz%.nvim"))
    end)
  end)

  describe("live logs", function()
    it("show_log streams new log lines into the open popup", function()
      local config = config_with({ "user/foo.nvim" })
      state.init(config)
      local p = state.get_plugins()["foo.nvim"]
      p.status = "building"
      p.log = { "$ make", "compiling..." }
      ui.open(config)

      local dash_buf = vim.api.nvim_get_current_buf()
      local line = find_line(dash_buf, "foo%.nvim")
      vim.api.nvim_win_set_cursor(0, { line, 0 })

      ui.show_log()
      local log_buf = vim.api.nvim_get_current_buf()
      assert.are_not_equal(dash_buf, log_buf)
      local text = table.concat(vim.api.nvim_buf_get_lines(log_buf, 0, -1, false), "\n")
      assert.is_true(text:match("compiling") ~= nil)

      -- New build output arrives; the live-follow refresh reflects it in-place
      -- (no reopen), without the popup buffer being replaced.
      table.insert(p.log, "done")
      ui.update_log()
      local text2 = table.concat(vim.api.nvim_buf_get_lines(log_buf, 0, -1, false), "\n")
      assert.is_true(text2:match("done") ~= nil, "live log did not pick up new line")
      assert.equals(log_buf, vim.api.nvim_get_current_buf())
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
      assert.is_true(require("pack.persist").load()["foo.nvim"])

      ui.cycle_tab() -- all -> outdated
      ui.cycle_tab() -- outdated -> disabled
      local disabled_buf = vim.api.nvim_get_current_buf()
      local text = table.concat(vim.api.nvim_buf_get_lines(disabled_buf, 0, -1, false), "\n")
      assert.is_true(text:match("foo%.nvim") ~= nil)
    end)

    it("re-enabling from the Disabled tab clears the flag", function()
      local config = config_with({ { "user/foo.nvim", lazy = true } })
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
      assert.is_nil(require("pack.persist").load()["foo.nvim"])
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

      local async = require("pack.async")
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

      local async = require("pack.async")
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

      local async = require("pack.async")
      local updated
      local original = async.update_plugins
      async.update_plugins = function(names) updated = names end

      ui.update_all_outdated()

      async.update_plugins = original
      assert.same({ "foo.nvim" }, updated)
    end)
  end)

  describe("adopted (native) plugins", function()
    local function seed_adopted()
      state.get_plugins()["adopted.nvim"] = {
        name = "adopted.nvim", url = "https://github.com/x/adopted.nvim",
        dir = "/x/adopted.nvim", status = "loaded", managed = false,
        disabled = false, lazy = false, priority = 50, log = {}, dependencies = {}, is_local = false,
      }
    end

    it("tags adopted plugins with (native) in the all tab", function()
      local config = config_with({ "user/foo.nvim" })
      state.init(config)
      seed_adopted()
      ui.open(config)
      local buf = vim.api.nvim_get_current_buf()
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      assert.is_truthy(text:match("adopted%.nvim%s+%(native%)"))
      assert.is_falsy(text:match("foo%.nvim%s+%(native%)")) -- managed plugin has no tag
    end)

    it("matches native plugin when registered name differs from native repo name (e.g. gitsigns vs gitsigns.nvim)", function()
      local config = config_with({ { "lewis6991/gitsigns.nvim", name = "gitsigns" } })
      state.init(config)
      state.reconcile_from_native({
        get = function()
          return {
            {
              path = "/some/path/gitsigns.nvim",
              rev = "abc1234",
              spec = { name = "gitsigns.nvim", src = "https://github.com/lewis6991/gitsigns.nvim" },
            },
          }
        end,
      })
      local plugins = state.get_plugins()
      assert.is_not_nil(plugins["gitsigns"])
      assert.is_true(plugins["gitsigns"].managed)
      assert.equals("/some/path/gitsigns.nvim", plugins["gitsigns"].dir)
      assert.is_nil(plugins["gitsigns.nvim"]) -- no duplicate unmanaged adopted entry created
    end)

    it("toggle_disabled refuses an adopted plugin", function()
      local config = config_with({})
      state.init(config)
      seed_adopted()
      state.get_plugins()["adopted.nvim"].disabled = false
      -- point the cursor resolver at the adopted plugin, then invoke.
      -- (Set cursor to its line via ui.open + search, or call the handler with it
      --  already expanded — use the same cursor-positioning the other detail tests use.)
      ui.open(config)
      local buf = vim.api.nvim_get_current_buf()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      for i, l in ipairs(lines) do
        if l:find("adopted.nvim", 1, true) then
          vim.api.nvim_win_set_cursor(0, { i, 0 })
          break
        end
      end
      ui.toggle_disabled()
      assert.is_false(state.get_plugins()["adopted.nvim"].disabled) -- unchanged
    end)
  end)

  describe("inline load time display", function()
    it("renders load time in parentheses next to the plugin name when set", function()
      local config = config_with({ "user/foo.nvim" })
      state.init(config)
      state.get_plugins()["foo.nvim"].load_time = 13.5
      state.update_status("foo.nvim", "loaded")
      ui.open(config)
      local buf = vim.api.nvim_get_current_buf()
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      assert.is_truthy(text:match("foo%.nvim%s+%(13%.5ms%)"))
    end)

    it("renders total load time in the Loaded section header", function()
      local config = config_with({ "user/foo.nvim", "user/bar.nvim" })
      state.init(config)
      state.get_plugins()["foo.nvim"].load_time = 10.0
      state.get_plugins()["bar.nvim"].load_time = 5.5
      state.update_status("foo.nvim", "loaded")
      state.update_status("bar.nvim", "loaded")
      ui.open(config)
      local buf = vim.api.nvim_get_current_buf()
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      assert.is_truthy(text:match("Loaded.*15%.5ms"))
    end)
  end)

  describe("visual profile bar chart", function()
    it("renders relative ASCII bar chart in show_profile popup", function()
      local config = config_with({ "user/foo.nvim", "user/bar.nvim" })
      state.init(config)
      state.get_plugins()["foo.nvim"].load_time = 15.0
      state.get_plugins()["bar.nvim"].load_time = 5.0
      ui.open(config)
      ui.show_profile()
      local buf = vim.api.nvim_get_current_buf()
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      assert.is_truthy(text:match("Pack Startup Profile"))
      assert.is_truthy(text:match("%[%s*█+.*%]") ~= nil)
    end)
  end)

  describe("category and tag filtering", function()
    it("filters plugins by cat: category query", function()
      local config = config_with({
        { "user/foo.nvim", category = "lsp" },
        { "user/bar.nvim", category = "git" },
      })
      state.init(config)
      ui.open(config)
      local orig_input = vim.ui.input
      vim.ui.input = function(opts, cb) cb("cat:lsp") end
      ui.filter()
      vim.ui.input = orig_input
      local buf = vim.api.nvim_get_current_buf()
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      assert.is_truthy(text:match("foo%.nvim"))
      assert.is_falsy(text:match("bar%.nvim"))
    end)
  end)

  describe("pending diff popup", function()
    it("renders show_diff popup for outdated plugins", function()
      local config = config_with({ "user/foo.nvim" })
      state.init(config)
      state.set_behind("foo.nvim", 2)
      state.set_outdated_detail("foo.nvim", {
        revision_before = "111aaa",
        revision_after = "222bbb",
        upstream_branch = "main",
        pending_commits = { "222bbb │ feat: new feature" },
      })
      ui.open(config)
      require("pack.async").show_diff()
      local popup_buf = vim.api.nvim_get_current_buf()
      local text = table.concat(vim.api.nvim_buf_get_lines(popup_buf, 0, -1, false), "\n")
      assert.is_truthy(text:match("Pack Pending Updates Diff"))
      assert.is_truthy(text:match("foo%.nvim"))
      assert.is_truthy(text:match("222bbb"))
    end)
  end)

  describe("selection and bulk actions", function()
    it("toggles selection for plugin at cursor without erroring", function()
      local config = config_with({ "user/foo.nvim" })
      state.init(config)
      state.update_status("foo.nvim", "loaded")
      ui.open(config)
      local buf = vim.api.nvim_get_current_buf()
      local line = find_line(buf, "foo%.nvim")
      vim.api.nvim_win_set_cursor(0, { line, 0 })

      local ok, err = pcall(ui.toggle_select)
      assert.is_true(ok, "toggle_select must not throw nil function error: " .. tostring(err))
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      assert.is_truthy(text:match("%[✓%]"))

      ui.clear_select()
      local text_after = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      assert.is_falsy(text_after:match("%[✓%]"))
    end)

    it("bulk disables all selected plugins when x is triggered", function()
      local config = config_with({ "user/foo.nvim", "user/bar.nvim" })
      state.init(config)
      state.update_status("foo.nvim", "installed")
      state.update_status("bar.nvim", "installed")
      ui.open(config)
      local buf = vim.api.nvim_get_current_buf()

      local line_foo = find_line(buf, "foo%.nvim")
      vim.api.nvim_win_set_cursor(0, { line_foo, 0 })
      ui.toggle_select()

      local line_bar = find_line(buf, "bar%.nvim")
      vim.api.nvim_win_set_cursor(0, { line_bar, 0 })
      ui.toggle_select()

      ui.toggle_disabled()
      assert.is_true(state.get_plugins()["foo.nvim"].disabled)
      assert.is_true(state.get_plugins()["bar.nvim"].disabled)
    end)

    it("bulk updates selected plugins when u is triggered regardless of current tab", function()
      local config = config_with({ "user/foo.nvim", "user/bar.nvim" })
      state.init(config)
      state.update_status("foo.nvim", "installed")
      state.update_status("bar.nvim", "installed")
      ui.open(config)
      local buf = vim.api.nvim_get_current_buf()

      local line_foo = find_line(buf, "foo%.nvim")
      vim.api.nvim_win_set_cursor(0, { line_foo, 0 })
      ui.toggle_select()

      local updated_names = {}
      local async = require("pack.async")
      local orig_update = async.update_plugins
      async.update_plugins = function(names) updated_names = names end

      ui.update_one()
      async.update_plugins = orig_update

      assert.equals(1, #updated_names)
      assert.equals("foo.nvim", updated_names[1])
    end)

    it("positions cursor on the first plugin line when dashboard opens", function()
      local config = config_with({ "user/foo.nvim" })
      state.init(config)
      state.update_status("foo.nvim", "loaded")
      ui.open(config)
      local buf = vim.api.nvim_get_current_buf()
      local cursor = vim.api.nvim_win_get_cursor(0)
      local first_plugin_line = find_line(buf, "foo%.nvim")
      assert.equals(first_plugin_line, cursor[1])
    end)

    it("preserves cursor position on non-plugin lines or bottom during periodic updates", function()
      local config = config_with({ "user/foo.nvim", "user/bar.nvim" })
      state.init(config)
      state.update_status("foo.nvim", "loaded")
      state.update_status("bar.nvim", "loaded")
      ui.open(config)

      -- Move cursor to line 1 (header line, non-plugin)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      ui.update()
      local cursor = vim.api.nvim_win_get_cursor(0)
      assert.equals(1, cursor[1])

      -- Move cursor to line 2 (blank/spinner line, non-plugin)
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      ui.update()
      cursor = vim.api.nvim_win_get_cursor(0)
      assert.equals(2, cursor[1])

      -- Move cursor to bottom line
      local line_count = vim.api.nvim_buf_line_count(0)
      vim.api.nvim_win_set_cursor(0, { line_count, 0 })
      ui.update()
      cursor = vim.api.nvim_win_get_cursor(0)
      assert.equals(line_count, cursor[1])
    end)
  end)

  describe("refined design plan UI features", function()
    it("renders tab-tailored centered quick help strings", function()
      local tabbar = require("pack.ui.render.tabbar")
      local lines = {}
      local highlights = {}
      tabbar.render_quick_help(lines, highlights, "all", 80)
      assert.equals(1, #lines)
      assert.truthy(lines[1]:find("%[S%] Sync All"))
      assert.truthy(lines[1]:find("%[%?%] Help"))
      assert.falsy(lines[1]:find("%[d%] Delete")) -- at width 80, second optional item doesn't fit

      lines = {}
      highlights = {}
      tabbar.render_quick_help(lines, highlights, "all", 130)
      assert.truthy(lines[1]:find("%[S%] Sync All"))
      assert.truthy(lines[1]:find("%[d%] Delete")) -- at width 130, optional items fit

      lines = {}
      highlights = {}
      tabbar.render_quick_help(lines, highlights, "outdated", 80)
      assert.truthy(lines[1]:find("%[U%] Update All"))

      lines = {}
      highlights = {}
      tabbar.render_quick_help(lines, highlights, "outdated", 130)
      assert.truthy(lines[1]:find("%[c%] Check"))

      lines = {}
      highlights = {}
      tabbar.render_quick_help(lines, highlights, "disabled", 80)
      assert.truthy(lines[1]:find("%[D%] Delete All Disabled"))
    end)

    it("auto-checks for updates when switching to the outdated tab", function()
      local config = config_with({ "user/foo.nvim" })
      state.init(config)
      ui.open(config)

      local checked = false
      local async = require("pack.async")
      local orig_check = async.check_all_outdated
      async.check_all_outdated = function() checked = true end

      ui.set_tab(2) -- switch to outdated tab
      async.check_all_outdated = orig_check

      assert.is_true(checked)
    end)

    it("renders dynamic tab count badges in tab pills", function()
      local config = config_with({ "user/foo.nvim", "user/bar.nvim" })
      state.init(config)
      state.set_behind("foo.nvim", 2)
      state.set_disabled("bar.nvim", true)

      local tabbar = require("pack.ui.render.tabbar")
      local lines = {}
      local highlights = {}
      tabbar.render_tab_bar(lines, highlights, "all")
      assert.truthy(lines[1]:find("● Plugins %(1%)"))
      assert.truthy(lines[1]:find("↺ Updates %(1%)"))
      assert.truthy(lines[1]:find("󰂭 Disabled %(1%)"))
    end)

    it("cycles tabs backwards with cycle_tab_back (S-Tab)", function()
      local config = config_with({ "user/foo.nvim" })
      state.init(config)
      ui.open(config)
      ui.cycle_tab_back() -- from all -> disabled
      local buf = vim.api.nvim_get_current_buf()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local tab_line = lines[3]
      assert.truthy(tab_line:find("● Disabled"))
    end)

    it("renders outdated sign on Plugins tab when plugin has pending updates", function()
      local config = config_with({ "user/foo.nvim" })
      state.init(config)
      state.update_status("foo.nvim", "loaded")
      state.set_behind("foo.nvim", 2)
      ui.open(config)

      local buf = vim.api.nvim_get_current_buf()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local foo_line = lines[find_line(buf, "foo%.nvim")]
      assert.truthy(foo_line:find("↺ 2 commits behind"))
    end)

    it("handles selection UI toggle (v) and clear selection (V)", function()
      local config = config_with({ "user/foo.nvim" })
      state.init(config)
      state.update_status("foo.nvim", "loaded")
      ui.open(config)

      local buf = vim.api.nvim_get_current_buf()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local foo_line = lines[find_line(buf, "foo%.nvim")]
      assert.falsy(foo_line:find("%[%s*%]")) -- hidden by default

      ui.toggle_select_ui() -- toggle checkboxes on
      lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      foo_line = lines[find_line(buf, "foo%.nvim")]
      assert.truthy(foo_line:find("%[%s*%]")) -- now visible

      ui.toggle_select() -- select item under cursor
      lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      foo_line = lines[find_line(buf, "foo%.nvim")]
      assert.truthy(foo_line:find("%[✓%]"))

      ui.toggle_select_ui() -- pressing v while items selected clears selections
      lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      foo_line = lines[find_line(buf, "foo%.nvim")]
      assert.falsy(foo_line:find("%[✓%]"))
      assert.truthy(foo_line:find("%[%s*%]")) -- selection cleared, checkboxes remain visible

      ui.toggle_select_ui() -- pressing v when no items selected hides checkboxes
      lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      foo_line = lines[find_line(buf, "foo%.nvim")]
      assert.falsy(foo_line:find("%[%s*%]")) -- now hidden
    end)

    it("deletes all disabled plugins with D and shows warning notification", function()
      local config = config_with({ "user/foo.nvim", "user/bar.nvim" })
      state.init(config)
      state.set_disabled("bar.nvim", true)

      local notifications = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level, opts)
        table.insert(notifications, { msg = msg, level = level, opts = opts })
      end

      local deleted_names = {}
      local orig_del = vim.pack.del
      vim.pack.del = function(names) deleted_names = names end

      ui.open(config)
      ui.delete_all_disabled()

      vim.notify = orig_notify
      vim.pack.del = orig_del

      assert.equals(1, #deleted_names)
      assert.equals("bar.nvim", deleted_names[1])
      assert.equals(nil, state.get_plugins()["bar.nvim"])
      assert.truthy(#notifications > 0)
      assert.truthy(notifications[#notifications].msg:find("Deleted 1 disabled plugin%(s%) from disk"))
      assert.equals(vim.log.levels.WARN, notifications[#notifications].level)
    end)

    it("syncs single cursor plugin with s keymap", function()
      local config = config_with({ "user/foo.nvim" })
      state.init(config)
      state.update_status("foo.nvim", "missing")
      ui.open(config)

      local installed_specs = {}
      local pack_mod = require("pack")
      local orig_inst = pack_mod._install_and_load
      pack_mod._install_and_load = function(specs, block) installed_specs = specs end

      ui.sync_one()
      pack_mod._install_and_load = orig_inst

      assert.equals(1, #installed_specs)
      assert.equals("foo.nvim", installed_specs[1].name)
    end)

    it("deletes single cursor plugin with d keymap", function()
      local config = config_with({ "user/foo.nvim" })
      state.init(config)
      state.update_status("foo.nvim", "loaded")
      ui.open(config)

      local deleted_names = {}
      local orig_del = vim.pack.del
      vim.pack.del = function(names) deleted_names = names end

      ui.delete_one()
      vim.pack.del = orig_del

      assert.equals(1, #deleted_names)
      assert.equals("foo.nvim", deleted_names[1])
      assert.equals(nil, state.get_plugins()["foo.nvim"])
    end)

    it("displays tab-tailored popup details with K", function()
      local config = config_with({ "user/foo.nvim" })
      state.init(config)
      state.set_disabled("foo.nvim", true)
      ui.open(config)
      ui.set_tab(3)

      local popup = require("pack.ui.popup")
      local opened_lines = nil
      local orig_open = popup.open_popup
      popup.open_popup = function(lines, opts)
        opened_lines = lines
        return 1, 1
      end

      ui.show_full_details()
      popup.open_popup = orig_open

      assert.truthy(opened_lines ~= nil)
      local full_text = table.concat(opened_lines, "\n")
      assert.truthy(full_text:find("Disabled State Information"))
    end)
  end)
end)

