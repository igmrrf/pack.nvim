# Dual-Style Plugin Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make pack.nvim track and display plugins from both declarative (lazy-style) and native imperative (`vim.pack.add`) usage in one config, distinguishing plugins it manages from ones it merely adopts.

**Architecture:** Three changes. (1) `state.reconcile_from_native` adopts unknown native plugins as `managed = false` records; declared records carry `managed = true`. (2) `setup()` is reordered so the `vim.pack.add` wrapper is installed before `load_plugins`/`import` runs, and a reconcile runs at the end of setup. (3) The dashboard tags adopted plugins `(native)` and gates managed-only actions.

**Tech Stack:** Lua, Neovim 0.12+ native `vim.pack`, plenary.nvim busted tests.

## Global Constraints

- Neovim 0.12+ (native `vim.pack` with `.add`/`.get`/`.update`/`.del`). Verbatim from spec.
- Install location + lockfile owned by native vim.pack — not configurable.
- Managed wins on name collision: never overwrite a managed record with an adopted one.
- Local (`dir=`) plugins never reach native and are never adopted.
- Run a single test file with (Directory form + explicit minimal_init so the child
  loads the repo copy, not any installed pack.nvim on the machine):
  `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/<file>.lua { minimal_init = 'tests/minimal_init.lua' }"`
- Full suite (canonical gate): `make test`.

---

## File Structure

- `lua/pack/state.lua` — add `managed` field to normalized records; extend `reconcile_from_native` to adopt unknown native plugins.
- `lua/pack/init.lua` — reorder `setup()`: install wrapper early, run reconcile at end.
- `lua/pack/ui.lua` — render `(native)` tag for adopted plugins; add `managed:` detail line; guard managed-only actions.
- `tests/state_spec.lua` — adoption + managed-field + collision tests.
- `tests/delegate_spec.lua` — wrapper-early ordering test (this file already holds setup/delegate tests).
- `tests/ui_spec.lua` — adopted-tag render test.

---

### Task 1: `managed` field + adoption in reconcile

**Files:**
- Modify: `lua/pack/state.lua` — `normalize` return table (~line 110-145), `reconcile_from_native` (line 274-307)
- Test: `tests/state_spec.lua`

**Interfaces:**
- Consumes: `M.reconcile_from_native(native_pack)` where `native_pack.get()` returns a list of `{ spec = { name, src }, path, rev }`.
- Produces: every record in `M.plugins` has a boolean `managed` field. Declared records: `managed = true`. Adopted records (added by reconcile): `managed = false`, with `url`, `dir`, `rev`, `status` (`"loaded"`/`"installed"`), and safe defaults (`disabled = false`, `lazy = false`, `priority = 50`, `log = {}`, `dependencies = {}`, `is_local = false`).

- [ ] **Step 1: Write the failing tests**

Add to `tests/state_spec.lua` before the final `end)` (line 125):

```lua
  it("declared plugins are marked managed = true", function()
    state.init(config_with({ "user/foo.nvim" }))
    assert.is_true(state.get_plugins()["foo.nvim"].managed)
  end)

  it("reconcile_from_native adopts an unknown native plugin as managed = false", function()
    state.init(config_with({ "user/foo.nvim" }))
    local rtp_dir = vim.api.nvim_list_runtime_paths()[1]
    local fake_native = {
      get = function()
        return {
          { spec = { name = "foo.nvim" }, path = "/some/foo.nvim", rev = "aaa" },
          { spec = { name = "adopted.nvim", src = "https://github.com/x/adopted.nvim" }, path = rtp_dir, rev = "bbb" },
        }
      end,
    }
    state.reconcile_from_native(fake_native)
    local a = state.get_plugins()["adopted.nvim"]
    assert.is_not_nil(a)
    assert.is_false(a.managed)
    assert.equals("https://github.com/x/adopted.nvim", a.url)
    assert.equals("loaded", a.status) -- path is on runtimepath
    assert.equals(50, a.priority)
    assert.is_false(a.disabled)
  end)

  it("reconcile_from_native does not overwrite a managed entry on name collision", function()
    state.init(config_with({ "user/foo.nvim" }))
    local before = state.get_plugins()["foo.nvim"]
    before.status = "installed"
    local fake_native = {
      get = function()
        return { { spec = { name = "foo.nvim" }, path = "/new/path/foo.nvim", rev = "ccc" } }
      end,
    }
    state.reconcile_from_native(fake_native)
    local after = state.get_plugins()["foo.nvim"]
    assert.is_true(after.managed) -- still managed, not clobbered
    assert.equals("/new/path/foo.nvim", after.dir) -- dir still refreshed
    assert.equals("ccc", after.rev)
  end)

  it("reconcile_from_native bumps generation only when it adopts", function()
    state.init(config_with({ "user/foo.nvim" }))
    local gen0 = state.generation
    state.reconcile_from_native({ get = function()
      return { { spec = { name = "foo.nvim" }, path = "/p/foo.nvim" } }
    end })
    assert.equals(gen0, state.generation) -- no new plugin, no bump
    state.reconcile_from_native({ get = function()
      return { { spec = { name = "new.nvim", src = "https://github.com/x/new.nvim" }, path = "/p/new.nvim" } }
    end })
    assert.equals(gen0 + 1, state.generation) -- one adopted
  end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/state_spec.lua { minimal_init = 'tests/minimal_init.lua' }"`
Expected: FAIL — `managed` is nil, `adopted.nvim` is nil after reconcile.

- [ ] **Step 3: Add `managed = true` to the normalized record**

In `lua/pack/state.lua`, in the table returned by `normalize` (after `is_local = is_local,` at line 143), add:

```lua
    local_dir = is_local and full_url or nil,
    managed = true,
  }
```

(Insert `managed = true,` as a new field in that return table.)

- [ ] **Step 4: Extend `reconcile_from_native` to adopt unknown plugins**

In `lua/pack/state.lua`, replace the `for _, entry in ipairs(list) do ... end` loop (lines 293-306) with:

```lua
  local adopted = 0
  for _, entry in ipairs(list) do
    local name = entry.spec and entry.spec.name
    if name then
      local p = M.plugins[name]
      if p then
        -- Managed or already-adopted record: refresh from native, keep `managed`.
        p.dir = entry.path or p.dir
        p.rev = entry.rev or p.rev
        if p.status == "missing" then
          p.status = "installed"
        end
        if p.status == "installed" and p.dir and rtp[vim.fs.normalize(p.dir)] then
          p.status = "loaded"
        end
      else
        -- Unknown to pack.nvim: adopt it (present in native, never declared).
        local on_rtp = entry.path and rtp[vim.fs.normalize(entry.path)] or false
        M.plugins[name] = {
          name = name,
          url = entry.spec and entry.spec.src or nil,
          dir = entry.path or "",
          rev = entry.rev,
          status = on_rtp and "loaded" or "installed",
          managed = false,
          disabled = false,
          lazy = false,
          priority = 50,
          log = {},
          dependencies = {},
          is_local = false,
        }
        adopted = adopted + 1
      end
    end
  end
  if adopted > 0 then
    M.generation = M.generation + 1
  end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/state_spec.lua { minimal_init = 'tests/minimal_init.lua' }"`
Expected: PASS (all state specs, including the four new ones).

- [ ] **Step 6: Commit**

```bash
git add lua/pack/state.lua tests/state_spec.lua
git commit -m "feat(state): mark managed records and adopt unknown native plugins"
```

---

### Task 2: Early wrapper install + end-of-setup reconcile

**Files:**
- Modify: `lua/pack/init.lua` — `M.setup` (lines 185-370)
- Test: `tests/delegate_spec.lua`

**Interfaces:**
- Consumes: `state.reconcile_from_native` (Task 1), `M.add`, `loader.init`, `collect_native_specs`, `M._install_and_load` (all existing).
- Produces: after `setup()` returns, `vim.pack.add ~= M.native_pack.add` (wrapper is live), and `state.get_plugins()` includes any plugin native already had on disk (adopted).

- [ ] **Step 1: Write the failing test**

Add to `tests/delegate_spec.lua` (inside its top-level `describe`, before the closing `end)`):

```lua
  it("installs the vim.pack.add wrapper and reconciles native plugins in setup", function()
    local pack = require("pack")
    local orig_vimpack = vim.pack
    local fake_native = {
      add = function() end,
      get = function()
        return { { spec = { name = "adopted.nvim", src = "https://github.com/x/adopted.nvim" }, path = "/x/adopted.nvim" } }
      end,
      del = function() end,
      update = function() end,
    }
    vim.pack = fake_native
    finally(function() vim.pack = orig_vimpack end)

    pack.setup({ plugins = {} })

    -- Wrapper is installed (not the raw native add).
    assert.are_not.equal(fake_native.add, vim.pack.add)
    -- Native-only plugin was adopted during setup.
    local a = require("pack.state").get_plugins()["adopted.nvim"]
    assert.is_not_nil(a)
    assert.is_false(a.managed)
  end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/delegate_spec.lua { minimal_init = 'tests/minimal_init.lua' }"`
Expected: FAIL — `adopted.nvim` is nil (reconcile not called in setup) and/or wrapper timing.

- [ ] **Step 3: Reorder `setup()` — finalize config and extract plugins before loading**

In `lua/pack/init.lua`, replace the body of `M.setup` from line 186 through line 215 (from `local plugins` down to the `M._install_and_load(collect_native_specs(...))` call) with the following. Leave everything from `-- Lazy-aware wrapper` (line ~217) and the `:Pack` command intact but MOVED as described in Step 4.

```lua
function M.setup(opts)
  -- Extract the raw plugins spec but DO NOT resolve it yet; load_plugins must run
  -- after the wrapper is installed so imperative `vim.pack.add` files register.
  local raw_plugins = opts and opts.plugins or nil
  if opts then opts.plugins = nil end
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  if M.config.performance and M.config.performance.vim_loader and vim.loader then
    vim.loader.enable()
  end

  -- Delegate all git operations to native vim.pack (preserved on M.native_pack).
  M.native_pack = vim.pack
  if not (M.native_pack and M.native_pack.add) then
    vim.notify("pack.nvim requires Neovim 0.12+ (native vim.pack)", vim.log.levels.ERROR)
    return
  end

  loader.init(M.config)
  require("pack.async").setup_build_hooks()
```

- [ ] **Step 4: Move the wrapper install ahead of plugin resolution**

Still in `M.setup`, immediately after the `require("pack.async").setup_build_hooks()` line added in Step 3, insert the wrapper block (this is the SAME code currently at lines 218-240, relocated here):

```lua
  -- Lazy-aware wrapper installed BEFORE load_plugins so imperative vim.pack.add
  -- calls (including files pulled in by `import`) route through pack.nvim.
  vim.pack = setmetatable({}, { __index = M.native_pack })
  vim.pack.add = function(specs)
    M.add(specs)
  end
  vim.pack.del = function(names)
    if type(names) == "string" then names = { names } end
    for _, name in ipairs(names) do
      local p = state.get_plugins()[name]
      if p then
        pcall(function() loader.remove_triggers(p) end)
        state.remove_plugin(name)
      end
    end
    native_call("del", M.native_pack.del, names)
  end
  vim.pack.update = function(names, update_opts)
    native_call("update", M.native_pack.update, names, update_opts)
  end
```

- [ ] **Step 5: Resolve plugins, register, install, then reconcile**

Immediately after the wrapper block from Step 4, insert:

```lua
  -- Now that the wrapper is live, resolve declarative specs and any imperative
  -- files (which call the wrapped vim.pack.add and register as they load).
  local plugins = load_plugins(raw_plugins)
  M.config.plugins = plugins or M.config.plugins

  state.init(M.config)

  -- Install (native) + load (ours) every configured, non-disabled plugin.
  M._install_and_load(collect_native_specs(state.get_plugins()), false)

  -- Adopt anything native already has on disk that was never declared to us
  -- (bootstrap line, pre-setup calls). Runs now so state is correct immediately.
  state.reconcile_from_native(M.native_pack)
```

Then DELETE the now-duplicated wrapper block that previously sat at lines 218-240 (it was relocated in Step 4). The `vim.api.nvim_create_user_command("Pack", ...)` block that follows stays exactly where it is.

- [ ] **Step 6: Run the test to verify it passes**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/delegate_spec.lua { minimal_init = 'tests/minimal_init.lua' }"`
Expected: PASS.

- [ ] **Step 7: Run the full suite to catch ordering regressions**

Run: `make test`
Expected: PASS (no regressions in loadflow/lifecycle/config specs from the reorder).

- [ ] **Step 8: Commit**

```bash
git add lua/pack/init.lua tests/delegate_spec.lua
git commit -m "feat(setup): install wrapper before import and reconcile at end of setup"
```

---

### Task 3: Dashboard — tag adopted plugins and gate disable

**Files:**
- Modify: `lua/pack/ui.lua` — `render_group` inner loop (lines 452-463), `quick_detail_lines` (lines 222-231), `toggle_disabled` (line 266)
- Test: `tests/ui_spec.lua`

**Interfaces:**
- Consumes: state records with `managed` (Task 1). The dashboard renders into a real buffer via `ui.open(config)`; tests read it with `vim.api.nvim_buf_get_lines`.
- Produces: adopted plugins render with a trailing ` (native)` on their name line; expanded detail shows a `managed:` line; `toggle_disabled` refuses adopted plugins.

Note: there is NO in-dashboard build/load action — those are `:Pack build`/`:Pack load` commands only. The single managed-only dashboard action is `toggle_disabled` (key `x`), which persists a disabled flag that only affects pack.nvim-controlled loading. update/sync (`u`/`U`/`S`) are native ops and stay enabled for adopted plugins.

- [ ] **Step 1: Write the failing tests**

Add to `tests/ui_spec.lua` inside the top-level `describe("pack.ui", ...)`, before its closing `end)`. Mirror the existing harness (`config_with`, `state.init`, `ui.open`, buffer reads):

```lua
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ui_spec.lua { minimal_init = 'tests/minimal_init.lua' }"`
Expected: FAIL — no `(native)` tag; `toggle_disabled` flips the flag.

- [ ] **Step 3: Append the `(native)` tag in render_group**

In `lua/pack/ui.lua`, in the `render_group` inner loop, change line 454:

```lua
        local line = string.format("    %s %s %s", expand_icon, icon, p.name)
```

to:

```lua
        local tag = (p.managed == false) and "  (native)" or ""
        local line = string.format("    %s %s %s%s", expand_icon, icon, p.name, tag)
```

Then after the existing highlight inserts in that loop (after line 461, before `add_plugin_details(...)`), add:

```lua
        if p.managed == false then
          table.insert(highlights, { line = #lines - 1, col_start = #line - #"  (native)", col_end = -1, hl = "Comment" })
        end
```

- [ ] **Step 4: Add the `managed:` line to `quick_detail_lines`**

In `lua/pack/ui.lua`, `quick_detail_lines` (lines 222-231) returns a list of strings. Add a `managed:` entry after the `status:` line:

```lua
local function quick_detail_lines(p)
  return {
    "url:      " .. p.url,
    "status:   " .. p.status,
    "managed:  " .. ((p.managed == false) and "no (native — lazy/config not controlled by pack.nvim)" or "yes"),
    "dir:      " .. p.dir,
    "lazy:     " .. tostring(p.lazy),
    "trigger:  " .. trigger_summary(p),
    "disabled: " .. tostring(p.disabled),
  }
end
```

- [ ] **Step 5: Gate `toggle_disabled` for adopted plugins**

In `lua/pack/ui.lua`, `M.toggle_disabled` (line 266) begins by resolving the plugin under the cursor (via `plugin_at_cursor()`). Immediately after that resolution and its nil-check, add:

```lua
  if p.managed == false then
    vim.notify("pack: '" .. p.name .. "' is native/adopted — pack.nvim does not control its loading", vim.log.levels.WARN)
    return
  end
```

(Use the local variable name `toggle_disabled` already assigns from `plugin_at_cursor()`; do not rename it.)

- [ ] **Step 6: Run the tests to verify they pass**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ui_spec.lua { minimal_init = 'tests/minimal_init.lua' }"`
Expected: PASS.

- [ ] **Step 7: Run the full suite**

Run: `make test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lua/pack/ui.lua tests/ui_spec.lua
git commit -m "feat(ui): tag adopted plugins (native) and gate disable"
```

---

### Task 4: End-to-end verification with a mixed config

**Files:**
- Test: `tests/loadflow_spec.lua` (add one integration-style case) — or a new `tests/dual_style_spec.lua` if loadflow's setup harness does not fit.

**Interfaces:**
- Consumes: full `pack.setup` (Task 2), adoption (Task 1).

- [ ] **Step 1: Write the failing integration test**

Add a test that drives `pack.setup` with a fake native_pack recording added specs, a declarative spec, and a pre-seeded native plugin, asserting all appear with correct `managed` flags:

```lua
  it("tracks declarative, wrapped-imperative, and adopted plugins together", function()
    local pack = require("pack")
    local state = require("pack.state")
    local added = {}
    local orig = vim.pack
    vim.pack = {
      add = function(specs) for _, s in ipairs(specs) do added[s.name] = true end end,
      get = function()
        return { { spec = { name = "adopted.nvim", src = "https://github.com/x/adopted.nvim" }, path = "/x/adopted.nvim" } }
      end,
      del = function() end, update = function() end,
    }
    finally(function() vim.pack = orig end)

    pack.setup({ plugins = { { "folke/flash.nvim" } } })
    -- imperative call after setup routes through the wrapper -> managed
    vim.pack.add({ { src = "https://github.com/user/imp.nvim", name = "imp.nvim" } })

    local plugins = state.get_plugins()
    assert.is_true(plugins["flash.nvim"].managed)      -- declarative
    assert.is_true(plugins["imp.nvim"].managed)        -- wrapped imperative
    assert.is_false(plugins["adopted.nvim"].managed)   -- native-only, adopted
  end)
```

- [ ] **Step 2: Run it to verify it fails, then passes**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/loadflow_spec.lua { minimal_init = 'tests/minimal_init.lua' }"`
Expected: FAIL before Tasks 1-2 land; PASS after. (If placing in a new file, run that file.)

- [ ] **Step 3: Run full suite**

Run: `make test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add tests/
git commit -m "test: end-to-end dual-style tracking (managed + adopted)"
```

---

## Self-Review Notes

- **Spec coverage:** Feature A → Task 1. Feature B → Task 2. Feature C → Task 3. Edge cases (collision, generation, local plugins) → Task 1 tests + Global Constraints. End-to-end → Task 4.
- **Placeholder scan:** All steps carry verbatim code against confirmed ui.lua line numbers (`quick_detail_lines` 222-231, `render_group` loop 452-463, `toggle_disabled` 266). No build/load dashboard action exists — only `toggle_disabled` is gated; documented in Task 3 header.
- **Type consistency:** `managed` is a boolean everywhere. Adopted records match the field set read by `render_all_tab` (`status`, `name`, `disabled`, `managed`) and `quick_detail_lines` (`url`, `status`, `dir`, `lazy`, `disabled`).
