# Dashboard Feature Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add help popup, plugin detail views, persisted disable/enable, outdated-plugin detection with update keymaps, three-tab navigation, and a test harness to the `:Packui` dashboard.

**Architecture:** Extend the existing `packui` modules (`state.lua`, `async.lua`, `loader.lua`, `ui.lua`) in place — no new top-level subsystems. One new pure-I/O module (`persist.lua`) owns the disabled-plugin JSON file. `ui.lua` gains a tab concept (`all`/`outdated`/`disabled`) rendered from the same `state.plugins` table plus two new fields (`disabled`, `behind`). All new interactive behavior is reachable from buffer-local keymaps on the existing dashboard buffer.

**Tech Stack:** Lua, Neovim 0.10+ APIs (`vim.uv`, `vim.json`, `vim.system`/`vim.fn.system`), plenary.nvim (busted-style tests, dev-only dependency), git CLI.

## Global Constraints

- Disabled-plugin state persists to `stdpath('config') .. '/packui-disabled.json'` as a plain JSON array of plugin names (spec: hand-editable).
- No true plugin "unload" — disabling an already-loaded plugin only warns; full unload requires restarting Neovim (spec: Neovim has no API to unregister a sourced plugin's own state).
- Corrupt/missing state files and failed git operations must degrade silently (WARN notify, empty/nil fallback) — never crash `setup()` or the dashboard.
- Search is native vim `/` — no code changes required for it; do not add a custom filter/prompt.
- Tests use plenary.nvim busted-style (`describe`/`it`), run headless via `nvim --headless -u tests/minimal_init.lua`.

---

### Task 1: Test harness bootstrap

**Files:**
- Create: `tests/minimal_init.lua`
- Create: `Makefile`
- Create: `.gitignore`
- Create: `tests/harness_spec.lua`

**Interfaces:**
- Produces: a working `make test` command that later tasks' spec files plug into. No Lua API surface.

- [ ] **Step 1: Create the minimal init that bootstraps plenary**

`tests/minimal_init.lua`:

```lua
local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local plenary_dir = root .. "/.tests/site/pack/deps/start/plenary.nvim"
if vim.fn.isdirectory(plenary_dir) == 0 then
  vim.fn.system({
    "git", "clone", "--depth=1",
    "https://github.com/nvim-lua/plenary.nvim",
    plenary_dir,
  })
end
vim.opt.runtimepath:prepend(plenary_dir)
vim.cmd("runtime plugin/plenary.vim")
```

- [ ] **Step 2: Create the Makefile test target**

`Makefile`:

```makefile
.PHONY: test

test:
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"
```

- [ ] **Step 3: Ignore the vendored test dependency**

`.gitignore`:

```
.tests/
```

- [ ] **Step 4: Write a smoke-test spec to prove the harness works**

`tests/harness_spec.lua`:

```lua
describe("test harness", function()
  it("runs a basic assertion", function()
    assert.equals(2, 1 + 1)
  end)

  it("can require plenary's busted helpers", function()
    assert.is_function(describe)
    assert.is_function(it)
    assert.is_function(assert.equals)
  end)
end)
```

- [ ] **Step 5: Run the harness and verify it passes**

Run: `make test`
Expected: output ends with `Success: 2` (or similar plenary summary showing 2 passing, 0 failing) and exit code 0.

- [ ] **Step 6: Commit**

```bash
git add tests/minimal_init.lua tests/harness_spec.lua Makefile .gitignore
git commit -m "test: bootstrap plenary.nvim test harness"
```

---

### Task 2: `persist.lua` — disabled-plugin JSON store

**Files:**
- Create: `lua/packui/persist.lua`
- Test: `tests/persist_spec.lua`

**Interfaces:**
- Produces: `persist.path()`, `persist.load() -> {[name:string]=true}`, `persist.save(set)`, `persist.set_disabled(name, bool) -> set`, `persist._set_path_for_testing(path_or_nil)` (test seam, overrides the file path used by `path()`).
- Consumes: nothing from other packui modules (pure I/O leaf module).

- [ ] **Step 1: Write the failing tests**

`tests/persist_spec.lua`:

```lua
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

  it("set_disabled adds and removes membership, persisting each time", function()
    persist.set_disabled("foo.nvim", true)
    assert.is_true(persist.load()["foo.nvim"])

    persist.set_disabled("foo.nvim", false)
    assert.is_nil(persist.load()["foo.nvim"])
  end)
end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: FAIL — `module 'packui.persist' not found`.

- [ ] **Step 3: Implement `persist.lua`**

`lua/packui/persist.lua`:

```lua
local M = {}

local override_path = nil

function M.path()
  return override_path or (vim.fn.stdpath("config") .. "/packui-disabled.json")
end

function M._set_path_for_testing(path)
  override_path = path
end

function M.load()
  local path = M.path()
  if vim.fn.filereadable(path) == 0 then
    return {}
  end

  local read_ok, lines = pcall(vim.fn.readfile, path)
  if not read_ok then
    vim.notify("packui: failed to read " .. path, vim.log.levels.WARN)
    return {}
  end

  local decode_ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decode_ok or type(decoded) ~= "table" then
    vim.notify("packui: " .. path .. " is not valid JSON, ignoring", vim.log.levels.WARN)
    return {}
  end

  local set = {}
  for _, name in ipairs(decoded) do
    if type(name) == "string" then
      set[name] = true
    end
  end
  return set
end

function M.save(set)
  local names = {}
  for name in pairs(set) do
    table.insert(names, name)
  end
  table.sort(names)

  local encode_ok, encoded = pcall(vim.json.encode, names)
  if not encode_ok then
    vim.notify("packui: failed to encode disabled-plugin list", vim.log.levels.ERROR)
    return false
  end

  local write_ok = pcall(vim.fn.writefile, { encoded }, M.path())
  if not write_ok then
    vim.notify("packui: failed to write " .. M.path(), vim.log.levels.ERROR)
    return false
  end
  return true
end

function M.set_disabled(name, disabled)
  local set = M.load()
  if disabled then
    set[name] = true
  else
    set[name] = nil
  end
  M.save(set)
  return set
end

return M
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: all `persist_spec.lua` tests pass, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lua/packui/persist.lua tests/persist_spec.lua
git commit -m "feat: add persisted disabled-plugin JSON store"
```

---

### Task 3: Wire `disabled`/`behind`/`checked_at` into `state.lua`

**Files:**
- Modify: `lua/packui/state.lua`
- Test: `tests/state_spec.lua`

**Interfaces:**
- Consumes: `persist.load() -> {[name]=true}`, `persist.save`/`set_disabled` (Task 2), `persist._set_path_for_testing` (test seam).
- Produces: plugin records now include `disabled` (bool), `behind` (number|nil), `checked_at` (number|nil). New functions `state.set_disabled(name, bool)` and `state.set_behind(name, count)` — later tasks (`ui.lua`, `async.lua`) call these instead of writing `state.plugins` fields directly.

- [ ] **Step 1: Write the failing tests**

`tests/state_spec.lua`:

```lua
local state = require("packui.state")
local persist = require("packui.persist")

describe("packui.state", function()
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

  local function config_with(plugins)
    return {
      install_path = vim.fn.tempname() .. "-packui-install",
      plugins = plugins,
    }
  end

  it("normalizes a bare string plugin spec and defaults disabled to false", function()
    state.init(config_with({ "user/foo.nvim" }))
    local p = state.get_plugins()["foo.nvim"]
    assert.is_not_nil(p)
    assert.equals("https://github.com/user/foo.nvim", p.url)
    assert.is_false(p.disabled)
  end)

  it("marks plugins disabled from the persisted set", function()
    persist.save({ ["foo.nvim"] = true })
    state.init(config_with({ "user/foo.nvim", "user/bar.nvim" }))
    local plugins = state.get_plugins()
    assert.is_true(plugins["foo.nvim"].disabled)
    assert.is_false(plugins["bar.nvim"].disabled)
  end)

  it("set_disabled updates in-memory state and persists", function()
    state.init(config_with({ "user/foo.nvim" }))
    state.set_disabled("foo.nvim", true)
    assert.is_true(state.get_plugins()["foo.nvim"].disabled)
    assert.is_true(persist.load()["foo.nvim"])
  end)

  it("set_behind stores the commit-behind count and a timestamp", function()
    state.init(config_with({ "user/foo.nvim" }))
    state.set_behind("foo.nvim", 3)
    local p = state.get_plugins()["foo.nvim"]
    assert.equals(3, p.behind)
    assert.is_number(p.checked_at)
  end)
end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: FAIL — `attempt to call field 'set_disabled' (a nil value)` and `disabled` assertions fail (field doesn't exist yet).

- [ ] **Step 3: Modify `state.lua`**

Add the require at the top of `lua/packui/state.lua`:

```lua
local persist = require("packui.persist")
```

In the `normalize()` function, extend the returned table (existing fields unchanged, add three new ones):

```lua
  return {
    url = full_url,
    name = name,
    lazy = plugin.lazy or false,
    cmd = plugin.cmd,
    event = plugin.event,
    ft = plugin.ft,
    keys = plugin.keys,
    main = plugin.main,
    opts = plugin.opts,
    config = config,
    dir = "",
    status = "unknown", -- missing, installed, loaded, error
    log = {},
    disabled = false,
    behind = nil,
    checked_at = nil,
  }
```

In `M.init(config)`, load the persisted set and apply it right after `normalize()` succeeds (before the `dir`/status computation, anywhere in the loop body works — insert right after the `if not normalized then ... goto continue end` block):

```lua
function M.init(config)
  M.plugins = {}
  local disabled_set = persist.load()
  for _, p in ipairs(config.plugins) do
    local normalized = normalize(p)
    if not normalized then
      vim.notify("packui: skipping invalid plugin spec (missing url): " .. vim.inspect(p), vim.log.levels.WARN)
      goto continue
    end
    normalized.disabled = disabled_set[normalized.name] or false
    -- Everything lives under opt/ and is packadd'd explicitly (lazily on
    -- trigger, or immediately in loader.init() for non-lazy plugins).
    -- :packadd only resolves pack/*/opt/{name} - a start/ package is only
    -- auto-loaded by Nvim's own startup scan, which runs before install_path
    -- is ever added to 'packpath', so start/ plugins installed or configured
    -- through packui would silently never load.
    normalized.dir = config.install_path .. "/opt/" .. normalized.name
    local legacy_start_dir = config.install_path .. "/start/" .. normalized.name

    if vim.fn.isdirectory(normalized.dir) == 0 and vim.fn.isdirectory(legacy_start_dir) == 1 then
      local parent_dir = vim.fn.fnamemodify(normalized.dir, ":h")
      vim.fn.mkdir(parent_dir, "p")
      vim.fn.rename(legacy_start_dir, normalized.dir)
    end

    if vim.fn.isdirectory(normalized.dir) == 1 then
      normalized.status = "installed"
    else
      normalized.status = "missing"
    end

    M.plugins[normalized.name] = normalized
    ::continue::
  end
end
```

Add the two new mutator functions after `M.update_status`:

```lua
function M.set_disabled(name, disabled)
  if not M.plugins[name] then
    return
  end
  M.plugins[name].disabled = disabled
  persist.set_disabled(name, disabled)
end

function M.set_behind(name, behind)
  if not M.plugins[name] then
    return
  end
  M.plugins[name].behind = behind
  M.plugins[name].checked_at = os.time()
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: all `state_spec.lua` tests pass, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lua/packui/state.lua tests/state_spec.lua
git commit -m "feat: track disabled/behind state, persist disabled flag"
```

---

### Task 4: `async.lua` — outdated detection

**Files:**
- Modify: `lua/packui/async.lua`
- Test: `tests/async_spec.lua`

**Interfaces:**
- Consumes: `state.set_behind(name, count)` (Task 3), existing `M.spawn` job-queue machinery.
- Produces: `M.spawn(plugin, cmd, args, cwd, on_exit)` — **signature change**: `on_exit` now receives `(code, stdout_text)` instead of just `(code)`; existing callers (`M.install`, `M.update_plugin`) are unaffected since Lua ignores extra arguments. `M.parse_behind_count(output) -> number|nil` (pure function). `M.check_outdated(plugin)` and `M.check_all_outdated()` — queue git fetch + rev-list for one/all eligible plugins.

- [ ] **Step 1: Write the failing tests**

`tests/async_spec.lua`:

```lua
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: FAIL — `attempt to call field 'parse_behind_count' (a nil value)`.

- [ ] **Step 3: Modify `async.lua`**

Add `local state = require("packui.state")` — already present at line 1, no change needed there.

Replace the body of `M.spawn` (the existing function) so the single `on_read` closure becomes a factory that also captures stdout, and `on_exit` is called with the captured text:

```lua
function M.spawn(plugin, cmd, args, cwd, on_exit)
  local stdout = vim.uv.new_pipe()
  local stderr = vim.uv.new_pipe()

  append_log(plugin, "$ " .. cmd .. " " .. table.concat(args, " "))

  local captured_stdout = {}

  local handle
  handle = vim.uv.spawn(cmd, {
    args = args,
    cwd = cwd,
    stdio = { nil, stdout, stderr }
  }, function(code, signal)
    stdout:read_stop()
    stderr:read_stop()
    stdout:close()
    stderr:close()
    handle:close()
    vim.schedule(function()
      if on_exit then on_exit(code, table.concat(captured_stdout, "\n")) end
    end)
  end)

  if not handle then
    stdout:close()
    stderr:close()
    append_log(plugin, "Failed to spawn " .. cmd)
    vim.schedule(function()
      if on_exit then on_exit(-1, "") end
    end)
    return
  end

  local function make_on_read(is_stdout)
    return function(err, data)
      if data then
        vim.schedule(function()
          for line in data:gmatch("([^\n]+)") do
            -- collapse carriage-return progress updates (e.g. git clone %) to the last segment
            local last = line:match("([^\r]*)$")
            if last ~= "" then
              append_log(plugin, last)
              if is_stdout then
                table.insert(captured_stdout, last)
              end
            end
          end
        end)
      end
    end
  end

  stdout:read_start(make_on_read(true))
  stderr:read_start(make_on_read(false))
end
```

Add `parse_behind_count`, `check_outdated`, and `check_all_outdated` after `M.update_plugin` (before `M.sync`):

```lua
function M.parse_behind_count(output)
  if type(output) ~= "string" then
    return nil
  end
  local digits = output:match("^%s*(%d+)%s*$")
  if not digits then
    return nil
  end
  return tonumber(digits)
end

function M.check_outdated(plugin)
  table.insert(queue, function(done)
    M.spawn(plugin, "git", { "fetch" }, plugin.dir, function(fetch_code)
      if fetch_code ~= 0 then
        done()
        return
      end
      M.spawn(plugin, "git", { "rev-list", "--count", "HEAD..@{upstream}" }, plugin.dir, function(count_code, output)
        if count_code == 0 then
          local behind = M.parse_behind_count(output)
          if behind then
            state.set_behind(plugin.name, behind)
            if package.loaded["packui.ui"] then
              require("packui.ui").update()
            end
          end
        end
        done()
      end)
    end)
  end)
  process_queue()
end

function M.check_all_outdated()
  for _, p in pairs(state.get_plugins()) do
    if not p.disabled and (p.status == "installed" or p.status == "loaded") then
      M.check_outdated(p)
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: all `async_spec.lua` tests pass. Also re-run the full suite to confirm the `M.spawn` signature change didn't break `persist`/`state` specs: `make test` should show 0 failures overall.

- [ ] **Step 5: Commit**

```bash
git add lua/packui/async.lua tests/async_spec.lua
git commit -m "feat: add git-fetch based outdated-plugin detection"
```

---

### Task 5: `loader.lua` — extract trigger lifecycle (setup/remove/enable)

**Files:**
- Modify: `lua/packui/loader.lua`
- Test: `tests/loader_spec.lua`

**Interfaces:**
- Consumes: nothing new externally; reuses existing local `setup_keys`/`normalize_key_entries`.
- Produces: `M.setup_triggers(p)` — registers a lazy plugin's `cmd`/ftdetect/`event`/`ft`/`keys` triggers (extracted from `M.init`'s loop body, now reusable). `M.remove_triggers(p)` — reverses `setup_triggers` (deletes its augroup, user commands, key mappings). `M.enable(p)` — re-activates a plugin after re-enabling: calls `setup_triggers` for lazy plugins, `M.load(name)` for non-lazy ones.

- [ ] **Step 1: Write the failing tests**

`tests/loader_spec.lua`:

```lua
local loader = require("packui.loader")

describe("packui.loader triggers", function()
  local function make_plugin(overrides)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local p = {
      name = "fixture.nvim",
      dir = dir,
      lazy = true,
      status = "installed",
    }
    return vim.tbl_extend("force", p, overrides or {})
  end

  it("registers a user command for a cmd trigger", function()
    local p = make_plugin({ cmd = "FixtureCmd" })
    loader.setup_triggers(p)
    local commands = vim.api.nvim_get_commands({})
    assert.is_not_nil(commands["FixtureCmd"])
    loader.remove_triggers(p)
  end)

  it("registers a FileType autocmd under a per-plugin augroup for a ft trigger", function()
    local p = make_plugin({ ft = "fixturefiletype" })
    loader.setup_triggers(p)
    local autocmds = vim.api.nvim_get_autocmds({ group = "packui_trigger_fixture.nvim" })
    assert.is_true(#autocmds > 0)
    loader.remove_triggers(p)
  end)

  it("calling setup_triggers twice does not error", function()
    local p = make_plugin({ cmd = "FixtureCmdTwice" })
    loader.setup_triggers(p)
    local ok = pcall(loader.setup_triggers, p)
    assert.is_true(ok)
    loader.remove_triggers(p)
  end)

  it("remove_triggers deletes the command and the augroup", function()
    local p = make_plugin({ cmd = "FixtureCmdRemove", event = "VimResized" })
    loader.setup_triggers(p)
    loader.remove_triggers(p)

    local commands = vim.api.nvim_get_commands({})
    assert.is_nil(commands["FixtureCmdRemove"])

    local ok = pcall(vim.api.nvim_get_autocmds, { group = "packui_trigger_fixture.nvim" })
    assert.is_false(ok)
  end)

  it("enable() does not error for a non-lazy installed plugin", function()
    local p = make_plugin({ lazy = false, status = "installed" })
    local ok = pcall(loader.enable, p)
    assert.is_true(ok)
  end)
end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: FAIL — `attempt to call field 'setup_triggers' (a nil value)`.

- [ ] **Step 3: Modify `loader.lua`**

Add a module-level `seen_cmds` table above `M.init` (promote it from the local variable currently declared inside `M.init`, so it persists across calls to `setup_triggers`/`remove_triggers`):

```lua
local seen_cmds = {}
```

Add `M.setup_triggers` and `M.remove_triggers` after `setup_keys` and before `M.init`:

```lua
function M.setup_triggers(p)
  local group
  if p.event or p.ft then
    group = vim.api.nvim_create_augroup("packui_trigger_" .. p.name, { clear = true })
  end

  if p.cmd then
    local cmds = type(p.cmd) == "table" and p.cmd or { p.cmd }
    for _, cmd in ipairs(cmds) do
      if seen_cmds[cmd] and seen_cmds[cmd] ~= p.name then
        vim.notify(
          "packui: command '" .. cmd .. "' already registered by " .. seen_cmds[cmd] .. ", overwriting for " .. p.name,
          vim.log.levels.WARN
        )
      end
      seen_cmds[cmd] = p.name
      vim.api.nvim_create_user_command(cmd, function(args)
        vim.api.nvim_del_user_command(cmd)
        M.load(p.name)
        local cmd_str = cmd
        if args.args and args.args ~= "" then
          cmd_str = cmd_str .. " " .. args.args
        end
        if args.bang then
          cmd_str = cmd_str .. "!"
        end
        pcall(vim.cmd, cmd_str)
      end, { nargs = "*", bang = true, complete = "file", force = true })
    end
  end

  local ftdetect_vim = vim.fn.globpath(p.dir, "ftdetect/*.vim", true, true)
  local ftdetect_lua = vim.fn.globpath(p.dir, "ftdetect/*.lua", true, true)
  for _, file in ipairs(ftdetect_vim) do
    local ok, err = pcall(vim.cmd, "source " .. vim.fn.fnameescape(file))
    if not ok then
      vim.notify("Error sourcing " .. file .. ": " .. tostring(err), vim.log.levels.ERROR)
    end
  end
  for _, file in ipairs(ftdetect_lua) do
    local ok, err = pcall(vim.cmd, "source " .. vim.fn.fnameescape(file))
    if not ok then
      vim.notify("Error sourcing " .. file .. ": " .. tostring(err), vim.log.levels.ERROR)
    end
  end

  if p.event then
    local events = type(p.event) == "table" and p.event or { p.event }
    for _, event in ipairs(events) do
      vim.api.nvim_create_autocmd(event, {
        group = group,
        once = true,
        callback = function()
          M.load(p.name)
        end,
      })
    end
  end

  if p.ft then
    local fts = type(p.ft) == "table" and p.ft or { p.ft }
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      pattern = fts,
      once = true,
      callback = function()
        M.load(p.name)
      end,
    })
  end

  if p.keys then
    setup_keys(p)
  end
end

function M.remove_triggers(p)
  pcall(vim.api.nvim_del_augroup_by_name, "packui_trigger_" .. p.name)

  if p.cmd then
    local cmds = type(p.cmd) == "table" and p.cmd or { p.cmd }
    for _, cmd in ipairs(cmds) do
      pcall(vim.api.nvim_del_user_command, cmd)
      if seen_cmds[cmd] == p.name then
        seen_cmds[cmd] = nil
      end
    end
  end

  if p.keys then
    for _, entry in ipairs(normalize_key_entries(p.keys)) do
      for _, mode in ipairs(entry.modes) do
        pcall(vim.keymap.del, mode, entry.lhs)
      end
    end
  end
end

function M.enable(p)
  if p.lazy then
    if p.status ~= "loaded" then
      M.setup_triggers(p)
    end
  else
    M.load(p.name)
  end
end
```

Simplify `M.init`'s loop to use `M.setup_triggers` and to skip disabled plugins entirely:

```lua
function M.init(config)
  -- :packadd resolves <packpath-entry>/pack/*/opt|start/<name>, and our plugin
  -- dirs live at install_path/opt|start/<name>, so the packpath entry must be
  -- install_path's grandparent (install_path itself must end in "pack/<name>").
  local packpath_root = vim.fn.fnamemodify(config.install_path, ":h:h")
  if vim.fn.fnamemodify(config.install_path, ":h:t") ~= "pack" then
    vim.notify(
      "packui: install_path '" .. config.install_path .. "' should end in 'pack/<name>' for :packadd to find plugins",
      vim.log.levels.WARN
    )
  end
  vim.opt.packpath:prepend(packpath_root)

  local plugins = state.get_plugins()

  for _, p in pairs(plugins) do
    if not p.disabled then
      if p.lazy and p.status == "installed" then
        M.setup_triggers(p)
      elseif not p.lazy and p.status == "installed" then
        if packadd(p.name) then
          state.update_status(p.name, "loaded")
          if p.config then
            vim.schedule(function()
              local ok, err = pcall(p.config)
              if not ok then
                vim.notify("Error loading config for " .. p.name .. ": " .. tostring(err), vim.log.levels.ERROR)
              end
            end)
          end
        end
      end

      if p.keys and (p.status == "installed" or p.status == "loaded") then
        setup_keys(p)
      end
    end
  end
end
```

Note `setup_keys(p)` is still called separately here (not folded into `setup_triggers`'s caller) because it must run for non-lazy plugins too, and `M.init`'s non-lazy branch doesn't call `setup_triggers`. `setup_triggers` itself still calls `setup_keys(p)` for the lazy case (unchanged from before the extraction), so calling it a second time from the bottom `if p.keys and ...` block for a lazy plugin would double-register those keymaps — restrict the bottom block to non-lazy plugins only:

```lua
      if not p.lazy and p.keys and p.status == "loaded" then
        setup_keys(p)
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: all `loader_spec.lua` tests pass, and the full suite (`persist`, `state`, `async`, `loader`, `harness`) still shows 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lua/packui/loader.lua tests/loader_spec.lua
git commit -m "refactor: extract loader trigger lifecycle into setup/remove/enable"
```

---

### Task 6: `ui.lua` — shared popup helper + help popup (`?`)

**Files:**
- Modify: `lua/packui/ui.lua`
- Test: `tests/ui_spec.lua`

**Interfaces:**
- Produces: local `open_popup(lines, opts) -> buf, win` (shared floating-window helper; `opts` may set `width_pct`, `height_pct`, `wrap`, `close_keys`). `M.show_help()`. Rewires the buffer-local `?` keymap.
- Consumes: nothing new.

- [ ] **Step 1: Write the failing test**

`tests/ui_spec.lua` (new file — later tasks append more `describe` blocks to it):

```lua
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
  while #vim.api.nvim_list_wins() > 1 do
    pcall(vim.api.nvim_win_close, 0, true)
  end
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
  end)
end)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test`
Expected: FAIL — `attempt to call field 'show_help' (a nil value)`.

- [ ] **Step 3: Modify `ui.lua`**

Add the shared popup helper and the keymap-help table near the top of the file (after the existing module-locals, before `M.open`):

```lua
local KEYMAP_HELP = {
  { key = "q", scope = "all", desc = "close" },
  { key = "?", scope = "all", desc = "show this help" },
  { key = "S", scope = "all", desc = "sync all (install missing, pull updates)" },
  { key = "Tab", scope = "all", desc = "cycle tabs: All -> Outdated -> Disabled" },
  { key = "Enter", scope = "all", desc = "quick details for plugin under cursor" },
  { key = "K", scope = "all", desc = "full details (commit info) for plugin under cursor" },
  { key = "l", scope = "all", desc = "view install/update logs for plugin under cursor" },
  { key = "x", scope = "All, Disabled", desc = "toggle disable/enable for plugin under cursor" },
  { key = "c", scope = "all", desc = "check for outdated plugins (git fetch)" },
  { key = "u", scope = "Outdated", desc = "update plugin under cursor" },
  { key = "U", scope = "Outdated", desc = "update all outdated plugins" },
  { key = "/", scope = "all", desc = "native vim search" },
}

local function open_popup(lines, opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local width = math.floor(vim.o.columns * (opts.width_pct or 0.6))
  local height = math.min(#lines + 2, math.floor(vim.o.lines * (opts.height_pct or 0.6)))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    border = "rounded",
    style = "minimal"
  })
  vim.wo[win].wrap = opts.wrap or false

  local keymap_opts = { noremap = true, silent = true }
  for _, key in ipairs(opts.close_keys or { "q" }) do
    vim.api.nvim_buf_set_keymap(buf, "n", key, "<Cmd>close<CR>", keymap_opts)
  end

  return buf, win
end

function M.show_help()
  local lines = { "  Packui Keymaps", "  ===============", "" }
  for _, entry in ipairs(KEYMAP_HELP) do
    table.insert(lines, string.format("  %-7s %-14s %s", entry.key, entry.scope, entry.desc))
  end
  open_popup(lines, { close_keys = { "q", "?", "<Esc>" } })
end
```

In `M.open`, add the `?` keymap alongside the existing ones:

```lua
  vim.api.nvim_buf_set_keymap(buf_id, "n", "?", "<Cmd>lua require('packui.ui').show_help()<CR>", opts)
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test`
Expected: `ui_spec.lua`'s help-popup test passes; full suite still 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lua/packui/ui.lua tests/ui_spec.lua
git commit -m "feat: add dashboard help popup (?)"
```

---

### Task 7: `ui.lua` — quick/full plugin details, move logs to `l`

**Files:**
- Modify: `lua/packui/ui.lua`
- Test: `tests/ui_spec.lua` (append)

**Interfaces:**
- Consumes: `open_popup` (Task 6).
- Produces: `M.show_details()` (Enter), `M.show_full_details()` (K). `M.show_log()` refactored to use `open_popup`. Buffer-local `<CR>` now opens quick details, `K` opens full details, `l` opens logs (moved off `<CR>`).

- [ ] **Step 1: Write the failing tests**

Append to `tests/ui_spec.lua` (inside the outer `describe("packui.ui", ...)` block, alongside the help-popup `describe`):

```lua
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: FAIL — `attempt to call field 'show_details' (a nil value)`.

- [ ] **Step 3: Modify `ui.lua`**

Replace `M.show_log` with a version built on `open_popup`, and add `plugin_at_cursor`, `trigger_summary`, `quick_detail_lines`, `M.show_details`, `M.show_full_details`. Insert these after `open_popup`/`M.show_help` and before the existing `M.show_log`:

```lua
local function plugin_at_cursor()
  local cursor = vim.api.nvim_win_get_cursor(0)
  return plugin_map[cursor[1]]
end

local function trigger_summary(p)
  local parts = {}
  if p.cmd then table.insert(parts, "cmd=" .. vim.inspect(p.cmd)) end
  if p.event then table.insert(parts, "event=" .. vim.inspect(p.event)) end
  if p.ft then table.insert(parts, "ft=" .. vim.inspect(p.ft)) end
  if p.keys then table.insert(parts, "keys=" .. vim.inspect(p.keys)) end
  if #parts == 0 then
    return "none"
  end
  return table.concat(parts, ", ")
end

local function quick_detail_lines(p)
  return {
    "  " .. p.name,
    "  " .. string.rep("=", #p.name),
    "",
    "  url:      " .. p.url,
    "  status:   " .. p.status,
    "  dir:      " .. p.dir,
    "  lazy:     " .. tostring(p.lazy),
    "  trigger:  " .. trigger_summary(p),
    "  disabled: " .. tostring(p.disabled),
  }
end

function M.show_details()
  local p = plugin_at_cursor()
  if not p then
    return
  end
  open_popup(quick_detail_lines(p), { height_pct = 0.4 })
end

function M.show_full_details()
  local p = plugin_at_cursor()
  if not p then
    return
  end

  local lines = quick_detail_lines(p)

  local commit_line = "(no commit info available)"
  if vim.fn.isdirectory(p.dir .. "/.git") == 1 then
    local result = vim.fn.system({ "git", "-C", p.dir, "log", "-1", "--format=%h %s" })
    if vim.v.shell_error == 0 and result ~= "" then
      commit_line = vim.trim(result)
    end
  end
  table.insert(lines, "  commit:   " .. commit_line)

  if p.behind ~= nil then
    table.insert(lines, "  behind:   " .. tostring(p.behind) .. " commit(s)")
  else
    table.insert(lines, "  behind:   not checked")
  end

  open_popup(lines, { height_pct = 0.5 })
end
```

Replace the existing `M.show_log` function body with:

```lua
function M.show_log()
  local p = plugin_at_cursor()
  if not p or not p.log or #p.log == 0 then
    vim.notify("No logs available for this item.", vim.log.levels.INFO)
    return
  end
  local buf = open_popup(p.log, { wrap = true })
  vim.bo[buf].filetype = "packui_log"
end
```

In `M.open`, replace the three existing keymap lines:

```lua
  vim.api.nvim_buf_set_keymap(buf_id, "n", "S", "<Cmd>PackuiSync<CR>", opts)
  vim.api.nvim_buf_set_keymap(buf_id, "n", "<CR>", "<Cmd>lua require('packui.ui').show_log()<CR>", opts)
```

with:

```lua
  vim.api.nvim_buf_set_keymap(buf_id, "n", "S", "<Cmd>PackuiSync<CR>", opts)
  vim.api.nvim_buf_set_keymap(buf_id, "n", "<CR>", "<Cmd>lua require('packui.ui').show_details()<CR>", opts)
  vim.api.nvim_buf_set_keymap(buf_id, "n", "K", "<Cmd>lua require('packui.ui').show_full_details()<CR>", opts)
  vim.api.nvim_buf_set_keymap(buf_id, "n", "l", "<Cmd>lua require('packui.ui').show_log()<CR>", opts)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: all `ui_spec.lua` tests pass; full suite 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lua/packui/ui.lua tests/ui_spec.lua
git commit -m "feat: add quick/full plugin details popups, move logs to 'l'"
```

---

### Task 8: `ui.lua` — three tabs (All / Outdated / Disabled)

**Files:**
- Modify: `lua/packui/ui.lua`
- Test: `tests/ui_spec.lua` (append)

**Interfaces:**
- Produces: `M.cycle_tab()` (bound to `<Tab>`). `M.update()` now renders whichever of `all`/`outdated`/`disabled` is current. Disabled plugins are excluded from the All tab.

- [ ] **Step 1: Write the failing tests**

Append to `tests/ui_spec.lua`:

```lua
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
      assert.is_true(text:match("%[all%]") ~= nil)
    end)
  end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: FAIL — `attempt to call field 'cycle_tab' (a nil value)`.

- [ ] **Step 3: Modify `ui.lua`**

Add a module-local tab state and helpers near the top (with the other module-locals like `win_id`):

```lua
local current_tab = "all"
local TAB_ORDER = { "all", "outdated", "disabled" }

local function next_tab(tab)
  for i, t in ipairs(TAB_ORDER) do
    if t == tab then
      return TAB_ORDER[(i % #TAB_ORDER) + 1]
    end
  end
  return TAB_ORDER[1]
end

local FOOTER_BY_TAB = {
  all = "  [S]ync  [x]disable  [Tab]next tab  [?]help  [q]uit",
  outdated = "  [u]pdate one  [U]pdate all  [c]heck  [Tab]next tab  [?]help  [q]uit",
  disabled = "  [x]enable  [Tab]next tab  [?]help  [q]uit",
}

function M.cycle_tab()
  current_tab = next_tab(current_tab)
  M.update()
end
```

In `M.open`, reset the tab to `"all"` whenever a fresh window is created (insert right before `buf_id = vim.api.nvim_create_buf(...)`):

```lua
  current_tab = "all"
```

Add the `<Tab>` keymap alongside the others in `M.open`:

```lua
  vim.api.nvim_buf_set_keymap(buf_id, "n", "<Tab>", "<Cmd>lua require('packui.ui').cycle_tab()<CR>", opts)
```

Replace the body of `M.update()`. The existing grouping/render_group logic is extracted into `render_all_tab`; two new render functions are added; `M.update` dispatches between them. Add these three local functions above `M.update`:

```lua
local function render_all_tab(lines, highlights)
  local plugins = state.get_plugins()

  local groups = {
    loaded = {},
    installed = {},
    missing = {},
    installing = {},
    updating = {},
    error = {}
  }

  for _, p in pairs(plugins) do
    if not p.disabled then
      if groups[p.status] then
        table.insert(groups[p.status], p)
      else
        table.insert(groups.installed, p)
      end
    end
  end

  for _, list in pairs(groups) do
    table.sort(list, function(a, b) return a.name < b.name end)
  end

  local function render_group(name, list, icon, hl_group)
    if #list > 0 then
      table.insert(lines, "  " .. name .. " (" .. #list .. ")")
      table.insert(highlights, { line = #lines - 1, col_start = 2, col_end = -1, hl = "Title" })
      for _, p in ipairs(list) do
        local line = string.format("    %s %s", icon, p.name)
        table.insert(lines, line)
        plugin_map[#lines] = p
        local icon_start = 4
        local icon_end = 4 + #icon
        table.insert(highlights, { line = #lines - 1, col_start = icon_start, col_end = icon_end, hl = hl_group })
      end
      table.insert(lines, "")
    end
  end

  render_group("Missing", groups.missing, config_ref.ui.icons.not_loaded, "DiagnosticError")
  render_group("Installing", groups.installing, config_ref.ui.icons.sync, "DiagnosticWarn")
  render_group("Updating", groups.updating, config_ref.ui.icons.sync, "DiagnosticWarn")
  render_group("Loaded", groups.loaded, config_ref.ui.icons.loaded, "DiagnosticOk")
  render_group("Installed (Not Loaded)", groups.installed, config_ref.ui.icons.loaded, "DiagnosticInfo")
  render_group("Errors", groups.error, config_ref.ui.icons.error, "DiagnosticError")
end

local function render_outdated_tab(lines, highlights)
  local outdated = {}
  for _, p in pairs(state.get_plugins()) do
    if not p.disabled and p.behind and p.behind > 0 then
      table.insert(outdated, p)
    end
  end
  table.sort(outdated, function(a, b) return a.name < b.name end)

  if #outdated == 0 then
    table.insert(lines, "  No outdated plugins (press c to check)")
    return
  end

  table.insert(lines, "  Outdated (" .. #outdated .. ")")
  table.insert(highlights, { line = #lines - 1, col_start = 2, col_end = -1, hl = "Title" })
  for _, p in ipairs(outdated) do
    table.insert(lines, string.format("    %s %d behind", p.name, p.behind))
    plugin_map[#lines] = p
  end
end

local function render_disabled_tab(lines, highlights)
  local disabled = {}
  for _, p in pairs(state.get_plugins()) do
    if p.disabled then
      table.insert(disabled, p)
    end
  end
  table.sort(disabled, function(a, b) return a.name < b.name end)

  if #disabled == 0 then
    table.insert(lines, "  No disabled plugins")
    return
  end

  table.insert(lines, "  Disabled (" .. #disabled .. ")")
  table.insert(highlights, { line = #lines - 1, col_start = 2, col_end = -1, hl = "Title" })
  for _, p in ipairs(disabled) do
    table.insert(lines, string.format("    %s (%s)", p.name, p.status))
    plugin_map[#lines] = p
  end
end
```

Replace `M.update()` itself with:

```lua
function M.update()
  if not buf_id or not vim.api.nvim_buf_is_valid(buf_id) then
    return
  end

  local cursor
  if win_id and vim.api.nvim_win_is_valid(win_id) then
    cursor = vim.api.nvim_win_get_cursor(win_id)
  end

  local lines = {}
  local highlights = {}
  plugin_map = {}

  table.insert(lines, "  Pack UI Dashboard [" .. current_tab .. "]")
  table.insert(lines, "  =================")
  table.insert(lines, "")

  if current_tab == "all" then
    render_all_tab(lines, highlights)
  elseif current_tab == "outdated" then
    render_outdated_tab(lines, highlights)
  else
    render_disabled_tab(lines, highlights)
  end

  table.insert(lines, FOOTER_BY_TAB[current_tab] or FOOTER_BY_TAB.all)
  table.insert(highlights, { line = #lines - 1, col_start = 2, col_end = -1, hl = "Comment" })

  vim.bo[buf_id].modifiable = true
  vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, lines)
  vim.bo[buf_id].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf_id, ns_id, 0, -1)
  table.insert(highlights, { line = 0, col_start = 2, col_end = -1, hl = "Title" })
  table.insert(highlights, { line = 1, col_start = 2, col_end = -1, hl = "Title" })
  for _, h in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(buf_id, ns_id, h.hl, h.line, h.col_start, h.col_end)
  end

  if cursor and win_id and vim.api.nvim_win_is_valid(win_id) then
    if cursor[1] > #lines then
      cursor[1] = #lines
    end
    pcall(vim.api.nvim_win_set_cursor, win_id, cursor)
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: all `ui_spec.lua` tests pass, full suite 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lua/packui/ui.lua tests/ui_spec.lua
git commit -m "feat: add All/Outdated/Disabled dashboard tabs"
```

---

### Task 9: `ui.lua` — disable/enable toggle (`x`)

**Files:**
- Modify: `lua/packui/ui.lua`
- Test: `tests/ui_spec.lua` (append)

**Interfaces:**
- Consumes: `state.set_disabled` (Task 3), `loader.remove_triggers`/`loader.enable` (Task 5).
- Produces: `M.toggle_disabled()` bound to `x`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/ui_spec.lua`:

```lua
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
  end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: FAIL — `attempt to call field 'toggle_disabled' (a nil value)`.

- [ ] **Step 3: Modify `ui.lua`**

Add `M.toggle_disabled` after `M.show_full_details`:

```lua
function M.toggle_disabled()
  local p = plugin_at_cursor()
  if not p then
    return
  end

  local new_disabled = not p.disabled
  state.set_disabled(p.name, new_disabled)

  if new_disabled then
    require("packui.loader").remove_triggers(p)
    if p.status == "loaded" then
      vim.notify(
        "packui: '" .. p.name .. "' disabled but already loaded - restart Neovim to fully unload it",
        vim.log.levels.WARN
      )
    end
  else
    require("packui.loader").enable(p)
  end

  M.update()
end
```

Add the `x` keymap in `M.open`:

```lua
  vim.api.nvim_buf_set_keymap(buf_id, "n", "x", "<Cmd>lua require('packui.ui').toggle_disabled()<CR>", opts)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: all `ui_spec.lua` tests pass, full suite 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lua/packui/ui.lua tests/ui_spec.lua
git commit -m "feat: add disable/enable toggle (x) to dashboard"
```

---

### Task 10: `ui.lua` — outdated re-check (`c`) and update keymaps (`u`/`U`)

**Files:**
- Modify: `lua/packui/ui.lua`
- Modify: `lua/packui/async.lua`
- Test: `tests/ui_spec.lua` (append)

**Interfaces:**
- Consumes: `async.check_all_outdated()` (Task 4), `async.update_plugin(plugin)` (existing).
- Produces: `M.update_one()` (bound to `u`), `M.update_all_outdated()` (bound to `U`), both Outdated-tab-scoped. `c` keymap wired to `async.check_all_outdated()`. `M.open` now also triggers a background outdated check. `async.update_plugin` resets `behind` to 0 on a successful pull.

- [ ] **Step 1: Write the failing tests**

Append to `tests/ui_spec.lua`:

```lua
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: FAIL — `attempt to call field 'update_one' (a nil value)`.

- [ ] **Step 3: Modify `async.lua`**

In `M.update_plugin`, reset the behind-count on a successful pull:

```lua
    M.spawn(plugin, "git", { "pull", "--rebase" }, plugin.dir, function(code)
      if code == 0 then
        state.update_status(plugin.name, was_loaded and "loaded" or "installed")
        state.set_behind(plugin.name, 0)
      else
        state.update_status(plugin.name, "error")
      end
      done()
      if package.loaded["packui.ui"] then
        require("packui.ui").update()
      end
    end)
```

- [ ] **Step 4: Modify `ui.lua`**

Add after `M.toggle_disabled`:

```lua
function M.update_one()
  if current_tab ~= "outdated" then
    return
  end
  local p = plugin_at_cursor()
  if not p then
    return
  end
  require("packui.async").update_plugin(p)
end

function M.update_all_outdated()
  if current_tab ~= "outdated" then
    return
  end
  for _, p in pairs(state.get_plugins()) do
    if not p.disabled and p.behind and p.behind > 0 then
      require("packui.async").update_plugin(p)
    end
  end
end
```

Add the `c`/`u`/`U` keymaps in `M.open`:

```lua
  vim.api.nvim_buf_set_keymap(buf_id, "n", "c", "<Cmd>lua require('packui.async').check_all_outdated()<CR>", opts)
  vim.api.nvim_buf_set_keymap(buf_id, "n", "u", "<Cmd>lua require('packui.ui').update_one()<CR>", opts)
  vim.api.nvim_buf_set_keymap(buf_id, "n", "U", "<Cmd>lua require('packui.ui').update_all_outdated()<CR>", opts)
```

At the end of `M.open` (after the initial `M.update()` call), trigger a background outdated check:

```lua
  M.update()
  require("packui.async").check_all_outdated()
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `make test`
Expected: all `ui_spec.lua` tests pass, full suite 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lua/packui/ui.lua lua/packui/async.lua tests/ui_spec.lua
git commit -m "feat: add outdated re-check (c) and update keymaps (u/U)"
```

---

### Task 11: Docs update and manual verification

**Files:**
- Modify: `README.md`

**Interfaces:** none (documentation only).

- [ ] **Step 1: Update the Dashboard Keymaps section**

In `README.md`, replace:

```markdown
## ⌨️ Dashboard Keymaps

When inside the dashboard (opened via `:Packui`), you can use the following keymaps:

*   `S` - Start a Sync operation (install/update).
*   `<Enter>` - Show git output logs for the plugin under the cursor.
*   `q` - Close the dashboard or the log view.
```

with:

```markdown
## ⌨️ Dashboard Keymaps

When inside the dashboard (opened via `:Packui`), you can use the following keymaps:

*   `q` - Close the dashboard or any popup.
*   `?` - Show the full keymap help popup.
*   `S` - Start a Sync operation (install/update).
*   `Tab` - Cycle tabs: All -> Outdated -> Disabled.
*   `<Enter>` - Quick details for the plugin under the cursor.
*   `K` - Full details (includes current commit) for the plugin under the cursor.
*   `l` - Show git output logs for the plugin under the cursor.
*   `x` - Toggle disable/enable for the plugin under the cursor (All and Disabled tabs). Disabling persists to `packui-disabled.json` in your Neovim config directory; an already-loaded plugin needs a restart to fully unload.
*   `c` - Check for outdated plugins (runs `git fetch` for every installed plugin).
*   `u` - Update the plugin under the cursor (Outdated tab).
*   `U` - Update every outdated plugin (Outdated tab).
*   `/` - Native vim search.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document new dashboard keymaps"
```

- [ ] **Step 3: Manual verification checklist**

Run: `nvim -u <your test init with packui configured and at least one real plugin>`, then `:Packui`, and exercise each of the following once (these depend on real git network access and can't be unit-tested):

1. Open dashboard, press `?` — help popup lists all keymaps, closes with `q`.
2. Press `Enter` on a plugin — quick details shown, no delay.
3. Press `K` on an installed plugin with a real git repo — full details show a real commit hash/message.
4. Press `l` on a plugin mid-sync — live log lines stream in.
5. Press `x` on an enabled, loaded plugin — dashboard notifies "disabled but already loaded - restart to fully unload"; press `x` again — plugin re-enabled, notification gone next open.
6. Press `x` on a lazy, not-yet-loaded plugin, then trigger its `cmd`/`event`/`ft` — confirm it does NOT load (trigger removed). Press `x` again to re-enable, retrigger — confirm it now loads.
7. Press `c` — after fetch completes, any plugin behind upstream appears under `Tab`-cycled Outdated tab with its count.
8. In Outdated tab, press `u` on one plugin — only that one updates; press `U` — all outdated plugins update and the tab empties out.
9. Confirm `/plugin-name<CR>` native search jumps the cursor to matches in the All tab.

Record any deviations found during this pass and fix before considering the feature complete.

---

## Self-Review Notes

- **Spec coverage:** help popup (Task 6), plugin details quick/full (Task 7), logs retained on `l` (Task 7), persisted disable/enable (Tasks 2, 3, 5, 9), outdated detection + update keymaps + tab (Tasks 4, 8, 10), search (native, no task needed — called out in Global Constraints) — all six original requirements map to a task.
- **Placeholder scan:** no TBD/TODO; every step has complete code.
- **Type/signature consistency checked:** `state.set_disabled(name, bool)`, `state.set_behind(name, count)`, `persist.set_disabled(name, bool)`, `loader.setup_triggers(p)`/`remove_triggers(p)`/`enable(p)`, `async.check_outdated(plugin)`/`check_all_outdated()`/`parse_behind_count(output)` are each defined once (Tasks 2–5) and referenced with matching names/arity in every later task.
- **`M.spawn` signature change** (Task 4) is called out explicitly as non-breaking for existing callers, since it's the one change with the widest blast radius in the codebase.
