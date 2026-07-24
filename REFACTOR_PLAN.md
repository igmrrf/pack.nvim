# Refactor Plan: delegate to native `vim.pack`

> **STATUS: COMPLETE** (phases 1-6, commits af9baae..0c51098). All 91 tests
> pass; verified end-to-end against real native vim.pack (eager + lazy) in an
> isolated XDG dir. Deviation: lock.lua deletion moved from phase 3 to phase 4
> (async dead-paths referenced it until then).

Neovim 0.12+ ships a native `vim.pack` (git installer + lockfile + updater +
version pinning). pack.nvim currently reimplements all git operations itself.
This refactor makes native `vim.pack` the git owner and keeps pack.nvim as the
lazy-loading / config / UI layer on top.

Decisions (locked):
- **Full delegation**: native owns install/update/del/lockfile/pin.
- **Fresh install**: no migration of old `.../pack/pack/opt` installs.
- **Keep custom UI**, re-sourced from `vim.pack.get()`.

## Target architecture

```
native vim.pack  ->  installer + lockfile + updater + version pinning (git owner)
pack.nvim layer  ->  spec translation, lazy triggers, config/opts/priority,
                     build hooks, UI, disable/enable
```

Native becomes a pure installer. We own 100% of loading via the `load`
**function** callback: native never touches rtp / `packadd` when `load` is
callable (`runtime/lua/vim/pack.lua` `pack_add`, ~line 800).

## Verified native facts (nvim 0.12.4)

- API: `add(specs, opts) / update(names, opts) / del(names) / get(names)`.
- Install dir fixed: `stdpath('data')/site/pack/core/opt` (not configurable).
- Lockfile: `stdpath('config')/nvim-pack-lock.json` (native format, indented,
  sorted, version serialized).
- `Spec = { src, name, version, data }`. `version` accepts branch, tag, OR
  commit hash (`is_tag_or_hash = copcall(git_get_hash, version)`). `data` is
  arbitrary per-plugin storage that round-trips through `get()`.
- `add(specs, { load = false })` = `packadd!` (dir on rtp, no source).
- `add(specs, { load = fn })` = calls `fn({spec,path})` and returns WITHOUT
  packadd. Plugin still marked `active` (set before the callable branch), so
  `get()` lists it.
- `add(specs, { confirm = false })` skips the native install confirm prompt.
- `PackChanged` / `PackChangedPre` autocmds: `pattern = plug.path`,
  `data = { active, kind='install'|'update'|'delete', spec, path }`.
- Native dir is under `site` -> already on packpath, so `:packadd <name>`
  resolves without prepending packpath ourselves.

## Core mechanism - the `load` callback

`vim.pack.add(native_specs, { load = load_fn, confirm = false })`

`load_fn(data)` does NOT load. It records `{name, path, meta = data.spec.data}`
into a pending list. Native calls it per-plugin in add-order, then returns.
AFTER `add()` returns we control loading:

- eager plugins -> sort by `priority`, `packadd` + run `config`
- lazy plugins  -> `setup_triggers` (event/ft/cmd/keys) that `packadd`+config on fire

This preserves priority order (native's per-plugin order can't) and gives full
inertness for lazy plugins.

## Spec translation (`state.normalize` -> native)

| pack.nvim | native `Spec` |
|---|---|
| `"user/repo"` / `src` / `[1]` | `src` (expand shorthand to full URL) |
| `as` / derived name | `name` |
| `commit` | `version = <sha>` |
| `tag` | `version = <tag>` |
| `branch` | `version = <branch>` |
| `version` / `sem_version` (range) | `version = vim.version.range(...)` |
| `lazy/event/ft/cmd/keys/config/opts/build/init/cond/priority/main/dependencies` | `data = { ...these... }` |

`version` precedence: `commit > tag > branch > version/sem_version`.

## Build hooks - `PackChanged`

One autocmd, `pattern='*'`:
```
PackChanged -> if data.kind in {install,update} and data.spec.data.build
               then run build (cwd = data.path)
```
Build runner uses `vim.system` (drop custom `spawn`). String build -> `sh -c`
(trusted-spec only). Function build -> pcall.

## Module-by-module

| Module | Change |
|---|---|
| async.lua | Gut it. Delete install/update_plugin/sync/restore/spawn/process_queue/queue. Keep only `check_outdated` (passive "N behind" for dashboard - native has no non-mutating query) + build runner, both on `vim.system`. |
| lock.lua | Delete. Native owns lockfile. |
| init.lua | `vim.pack.add` wrapper builds native specs + calls native + runs post-add loader. Commands: sync/update -> `vim.pack.update`, delete -> `vim.pack.del`, restore -> `vim.pack.update(nil,{target='lockfile'})`, clean -> `del` orphans (get() vs configured). install_missing -> native installs on add() automatically. |
| loader.lua | Add `load_fn` + post-add priority loader. Keep `package.loaders` disabled-mock/require-lazy searcher. Drop packpath munging. Keep ftdetect build_cache. |
| state.lua | Thin cache: our meta (from spec.data) + runtime (status, behind, log, load_time). Reconcile status from `vim.pack.get()`. `normalize` emits native spec + meta. Keep `safe_ref`. |
| persist.lua | Keep unchanged. Disabled plugins simply not passed to `vim.pack.add`. |
| ui.lua | Render from merged view (`vim.pack.get()` + state meta). Buttons -> `vim.pack.update`, check_outdated kept, disable via persist. Keep tabs/filter/log/extmark. |

## Open items / risks

1. Disabled + already-installed: disabling => not `add()`ed, dir stays on disk
   (native still tracks in lockfile). `Pack clean` handles orphans.
2. Dependencies: pack.nvim BFS-expands deps into separate plugins. Native has
   no dep concept -> keep expanding deps into `native_specs` ourselves; enforce
   dep load order in our loader, not native.
3. `confirm=false` for startup install; `Pack sync` may keep native confirm
   buffer; `U` in dashboard -> `vim.pack.update(names,{force=true})`.
4. `check_outdated` still shells `git fetch`/`rev-list` - the one residual git
   use, by design.
5. Native `update()` opens its own confirm tabpage - coexists with dashboard.

## Test plan

- Rewrite `async_spec` -> build-hook-on-PackChanged + check_outdated (keep
  real-git test).
- Drop lock coverage; add spec-translation tests (commit/tag/branch/range ->
  native `version`).
- New `load_fn` test: eager loads by priority, lazy registers triggers, native
  never sources (assert not on rtp until trigger).
- Adapt state spec to get()-sourced status. Keep loader/ui/persist specs.
- Stub `vim.pack` in tests (inject fake) - real add() hits network.

## Phased execution

1. Spec translation + normalize -> native spec shape, meta in `data`. (tests)
2. Loader `load_fn` + post-add priority loader; drop packpath munging. (tests)
3. init.lua add() wrapper + commands -> delegate. Delete lock.lua.
4. Build hooks on PackChanged; gut async.lua to check_outdated + build (vim.system).
5. UI re-source from get()+state.
6. Full test pass + headless smoke (fake vim.pack) + real-nvim manual verify.
