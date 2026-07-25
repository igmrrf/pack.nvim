# Dual-Style Plugin Tracking (lazy-style + native imperative)

**Date:** 2026-07-25
**Status:** Approved design, pending implementation
**Branch:** refactor/native-vim-pack

## Goal

pack.nvim should be a drop-in replacement for lazy.nvim (declarative specs) **and**
transparently support native `vim.pack` usage — including both styles in the same
config. Every plugin installed by any means must appear correctly in the dashboard,
with a clear distinction between plugins pack.nvim **manages** and plugins it has
merely **adopted**.

## Background / Problem

Two independent bugs make the two styles mutually exclusive today:

1. **Import drops imperative files.** `load_plugins` (init.lua:67-77) only registers a
   module when `require(file)` returns a `table`. Config files written in native
   imperative style (call `vim.pack.add(...)` + `require(x).setup()` at top level, no
   `return`) yield `true` from `require`, so `{ import = "dir" }` silently registers
   nothing.

2. **Wrapper installed too late.** `setup()` installs the lazy-aware `vim.pack.add`
   wrapper at the *end* (init.lua:218-221). Anything that calls `vim.pack.add` before
   that point (bootstrap, or imperative files pulled in by `import` mid-setup) hits
   *native* `vim.pack.add`, which never registers into pack.nvim state.

Observed symptom: a real config (`~/.config/nvim`) with 36 imperative plugin files
and `{ import = "plugins" }` shows only `pack.nvim` in the dashboard. Reproduced:
requiring the same files *after* setup (wrapper live) registers them (state count
1 → 6 in a controlled repro).

### Decision

Full adoption: the dashboard shows **every** plugin native `vim.pack` has on disk.
Plugins not declared to pack.nvim are shown but clearly marked as unmanaged.
Additionally, install the wrapper early so post-setup-start `vim.pack.add` calls are
managed rather than merely adopted.

## Terminology

- **managed** (`managed = true`) — declared to pack.nvim via the spec list, an
  `import` module returning specs, or `vim.pack.add` routed through the wrapper.
  pack.nvim owns its lazy/event/keys/config/build/priority behavior.
- **adopted** (`managed = false`) — present in native `vim.pack.get()` but never
  declared to pack.nvim (bootstrap line, pre-setup call, raw imperative file whose
  `vim.pack.add` hit native). pack.nvim displays it and supports native ops
  (update/delete/sync), but does **not** drive its lazy-loading or config — it loaded
  itself.

## Design

### Feature A — Full adoption via reconcile

Extend `state.reconcile_from_native(native_pack)` (state.lua:274-307). Today it only
*updates* existing entries. Make it also **add** records for native plugins absent
from `M.plugins`.

Adopted record shape (built from a `vim.pack.get()` entry + runtimepath check):

- `name` = `entry.spec.name`
- `url` = `entry.spec.src`
- `dir` = `entry.path`
- `rev` = `entry.rev`
- `status` = `"loaded"` if `vim.fs.normalize(entry.path)` is in runtimepath, else
  `"installed"`
- `managed = false`
- `disabled = false`
- lazy/event/ft/cmd/keys/pattern/config/opts/build/priority = defaults (nil / `50`)
- `is_local = false`, `log = {}`

Bump `M.generation` when at least one adopted record is added (so cached derived
views rebuild).

Collision rule: if a name already exists in `M.plugins`, **managed wins** — never
overwrite a managed record with an adopted one. Only refresh `dir`/`rev`/`status`
from native (existing behavior at state.lua:296-306), leaving `managed` untouched.

Existing declared records get `managed = true` set at registration (Feature C).

### Feature B — Early wrapper install + end-of-setup reconcile

Reorder `setup()` (init.lua:185-370) so the `vim.pack.add`/`del`/`update` wrapper is
installed **before** `load_plugins` runs.

Target order:

1. Finalize config: `vim.tbl_deep_extend`, enable `vim.loader`, extract the raw
   `opts.plugins` value (do **not** run `load_plugins` yet).
2. Resolve `M.native_pack = vim.pack`; verify 0.12+ (`native_pack.add` exists); bail
   with the existing error notify if not.
3. `loader.init(M.config)` and ensure `state` is usable. `state.init` for the
   *declared* specs runs after they are collected (step 6), but `state.add_plugin`
   must work standalone before then — it already does (defaults `M.plugins = {}`).
4. `require("pack.async").setup_build_hooks()`.
5. Install wrapper: `vim.pack.add = function(specs) M.add(specs) end`, plus the
   `del`/`update` overrides (unchanged bodies). `vim.pack` is the
   `setmetatable({}, { __index = M.native_pack })` proxy.
6. `local plugins = load_plugins(raw_plugins)`; `M.config.plugins = plugins`;
   register them (`state.init` / `state.add_plugin` loop) with `managed = true`.
7. `M._install_and_load(collect_native_specs(state.get_plugins()), false)`.
8. `state.reconcile_from_native(M.native_pack)` — adopt anything native has that is
   still unregistered (bootstrap plugin, imperative files that already installed via
   the wrapper are managed by now; anything pre-setup is adopted).
9. Create the `:Pack` user command (unchanged).

Effects:

- Imperative files pulled in by `import` during step 6 call the **wrapped**
  `vim.pack.add` → `M.add` → managed + installed immediately (nested install during
  setup; idempotent, deduped by name in `state.add_plugin`).
- Top-level `vim.pack.add` after setup → managed (unchanged from today).
- Plugins added *before* `setup()` (e.g. the bootstrap `vim.pack.add` for pack.nvim
  itself) remain adopted, then reconciled — and pack.nvim's own entry is superseded
  by its managed spec if declared (collision rule).

Also add the end-of-setup reconcile (step 8) so state is correct immediately, rather
than only when the dashboard first opens (currently ui.lua:310).

### Feature C — Dashboard: managed vs adopted clarity

- Add `managed` to every state record: `true` in `normalize`/`add_plugin`
  (state.lua), `false` in adopted reconcile records.
- Render (`render_all_tab`, ui.lua:433-475): keep grouping by `status`. Append a
  source tag to adopted plugins' lines, e.g. `    ▶ ● oil.nvim  (native)`, with the
  `(native)` span highlighted `Comment`. Managed plugins render unchanged.
- Detail view (`add_plugin_details`, around ui.lua:225): add a line
  `managed:  yes` / `managed:  no (native — lazy/config not controlled by pack.nvim)`.
- Actions: update/delete/sync work for adopted plugins (native ops). Build/load/lazy
  actions are no-ops or hidden for adopted plugins (nothing declared to act on). If an
  action keyed on a managed-only field is invoked on an adopted plugin, notify
  "not managed by pack.nvim" rather than erroring.

## Edge Cases

- **Local (`dir=`) plugins:** never in `vim.pack.get()`. Stay managed; untouched by
  adoption.
- **pack.nvim itself:** bootstrapped pre-setup via native. Adopted unless declared in
  the spec list; when declared, managed wins.
- **Disabled plugins:** an adopted plugin has no persisted disabled state; treated as
  enabled. `persist` disabled-set only applies to managed records (unchanged).
- **Name collision across styles:** same plugin declared *and* present natively →
  single managed record, dir/rev/status refreshed from native.
- **Generation bump:** only when adoption actually adds a record, so loader's
  module→plugin cache rebuilds.

## Testing

Add to the existing test suite (mirror current state/loader test style):

1. `reconcile_from_native` adds an unknown native entry as `managed = false`, status
   derived from runtimepath.
2. `reconcile_from_native` does **not** overwrite a managed entry on name collision;
   `managed` stays `true`, dir/rev/status refresh.
3. Adopted record carries expected defaults (nil lazy/config, priority 50).
4. Declared specs get `managed = true`.
5. Wrapper-early: a `vim.pack.add` call issued after setup-start routes to `M.add`
   (managed), not native. (Unit-level: assert `vim.pack.add ~= M.native_pack.add`
   after step 5 ordering.)
6. `generation` increments when adoption adds ≥1 record; unchanged when it adds none.
7. Integration-style (headless nvim, like the repro): a config mixing a declarative
   spec, an `import` dir of imperative files, and a bare `vim.pack.add` results in all
   plugins present, correctly tagged managed/adopted.

## Out of Scope

- Converting the user's existing imperative config files (separate, optional task).
- Persisting disabled state for adopted plugins.
- Migrating adopted → managed automatically (user can declare them if they want
  lazy/config control).
