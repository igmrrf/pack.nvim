# Dashboard Feature Expansion — Design

Date: 2026-07-23

## Problem

The `:Packui` dashboard (`lua/packui/ui.lua`) currently supports only: close (`q`), sync (`S`), and a log popup (`Enter`). We need six additions: help/keymap popup, plugin detail view, continued log access, persisted enable/disable, outdated-plugin detection with update keymaps, and search. This spec covers all six as one unit since they share the same buffer, keymap surface, and state model.

## Data model changes (`state.lua`)

Add three fields to the plugin record produced by `normalize()`:

- `disabled` (boolean, default `false`)
- `behind` (number or `nil`) — commits behind upstream; `nil` means "not yet checked"
- `checked_at` (number or `nil`) — `os.time()` of last outdated check

`M.init()` loads the disabled set from `persist.lua` and applies it to each plugin's `disabled` field after normalization.

## New module: `packui/persist.lua`

Pure I/O module, no UI dependency:

```lua
M.path()            -- stdpath('config') .. '/packui-disabled.json'
M.load()            -- returns a set {[name]=true}; {} on missing/corrupt file (notify WARN on corrupt)
M.save(set)          -- writes sorted array of names as JSON
M.set_disabled(name, bool) -- read-modify-write convenience used by the UI toggle
```

Format is a plain JSON array of plugin names, e.g. `["foo.nvim", "bar.nvim"]`, so users can hand-edit it. File lives in `stdpath('config')`, not `install_path`, so it survives even if `install_path` changes.

## Outdated detection (`async.lua`)

New function `M.check_outdated(plugin)`:

1. Skip if `plugin.disabled` or `plugin.status` not in `{installed, loaded}`.
2. Queue `git fetch` in `plugin.dir`.
3. On success, queue `git rev-list --count HEAD..@{upstream}`.
4. Parse the numeric output with a pure helper `M.parse_behind_count(output)` (extracted so it's unit-testable without spawning git) and store into `state`, updating `plugin.behind` and `plugin.checked_at`.
5. On any failure (no upstream configured, network error, detached HEAD), leave `plugin.behind = nil` — the plugin simply doesn't appear as outdated. No error popup.

`M.check_all_outdated(config)` iterates all eligible plugins through the existing job queue (reuses `process_queue`/`max_jobs`).

Triggered:
- Automatically, non-blocking, whenever `ui.open()` runs.
- Manually via `c` (re-check), from any tab.

## Loader changes (`loader.lua`)

Extract the per-plugin lazy-trigger setup (currently the `p.lazy` branch inside `M.init`'s loop, lines 100–165) into a standalone `M.setup_triggers(p)`, called both from `M.init()` (unchanged behavior) and from the new enable path below. This is the one refactor motivated directly by this feature (enabling a plugin needs to re-register triggers dynamically, and no such per-plugin entry point exists today).

## Disable / enable

Toggle key `x` (works in **All** and **Disabled** tabs) on the plugin under cursor:

- **Disabling**: set `disabled = true`, persist via `persist.set_disabled(name, true)` immediately. Remove any lazy triggers already registered (`pcall` delete keymaps/autocmds/user-commands the plugin owns) so it stops loading on next trigger. Excluded from `sync` and from outdated-checks going forward. If the plugin is already `loaded` (packadd'd), `vim.notify` warns that full unload requires restarting Neovim (Neovim has no API to unregister a plugin's own autocmds/commands/globals once sourced) — no automatic restart.
- **Enabling**: clear `disabled`, persist. If plugin is lazy and not currently loaded, call `loader.setup_triggers(p)` to re-register its `cmd`/`event`/`ft`/`keys` triggers immediately. If non-lazy, call the existing `loader.load(name)` immediately.

## Dashboard tabs

`Tab` cycles **All → Outdated → Disabled → All**. Tab state is local to the open dashboard session (not persisted).

- **All**: existing status groups (missing/installing/updating/loaded/installed/error). Disabled plugins are excluded from this tab entirely.
- **Outdated**: plugins where `behind ~= nil and behind > 0`, sorted by name. Empty-state line: "No outdated plugins (press c to check)."
- **Disabled**: all `disabled == true` plugins, showing name + last known status.

Footer hint line changes per active tab to reflect available keys.

## Keymaps (buffer-local)

| Key | Tab(s) | Action |
|---|---|---|
| `q` | all | close |
| `?` | all | help popup: full keymap list |
| `S` | all | sync all (existing, skips disabled) |
| `Tab` | all | cycle tabs |
| `Enter` | all | quick details popup (no spawn) |
| `K` | all | full details popup (spawns `git log -1`) |
| `l` | all | view logs (existing `show_log`, moved off `Enter`) |
| `x` | All, Disabled | toggle disable/enable on cursor plugin |
| `c` | all | force re-check outdated for all eligible plugins |
| `u` | Outdated | update cursor plugin |
| `U` | Outdated | update all outdated plugins |
| `/` | all | native vim search (no list filtering — just jump/highlight) |

## Detail popups

**Quick details** (`Enter`): name, url, status, dir, lazy flag + trigger config (`cmd`/`event`/`ft`/`keys`), disabled flag. Reads only from `state` — no process spawn, safe to open repeatedly.

**Full details** (`K`): everything in quick details, plus current commit hash + subject line (`git log -1 --format=%h %s`, spawned synchronously via `vim.fn.system` since it's a single fast local call) and the `behind`/`checked_at` outdated info if known.

## Help popup (`?`)

Static floating buffer listing the full keymap table above (key, tab-scope, description). Closes on `q`/`?`/`Esc`.

## Error handling

- Corrupt/unreadable `packui-disabled.json` → `vim.notify` WARN, treat as empty set, don't block `setup()`.
- git fetch/rev-list failure → `plugin.behind` stays `nil`, silently excluded from Outdated tab.
- `git log -1` failure in full-details popup → show "(no commit info available)" line instead of erroring.

## Testing

No test infrastructure exists in this repo today. This spec adds one: **plenary.nvim**, busted-style (`describe`/`it`), run headless.

- `tests/minimal_init.lua` — bootstraps a minimal runtimepath including plenary (cloned as a dev-only dependency, not a runtime dependency of packui) and this plugin.
- `tests/persist_spec.lua` — load/save round-trip, missing file → empty set, corrupt JSON → empty set + warning, `set_disabled` toggling.
- `tests/state_spec.lua` — `normalize()` regression coverage plus new `disabled` field wiring from `persist.load()`.
- `tests/async_spec.lua` — `parse_behind_count()` pure-function cases (well-formed count, empty/garbage output, negative/zero).
- `tests/loader_spec.lua` — `setup_triggers()` registers `cmd`/`event`/`ft`/`keys` correctly for a fixture lazy plugin spec, and that calling it twice doesn't double-register.
- `tests/ui_spec.lua` — headless-open `:Packui`, assert tab cycling changes buffer content, assert disabled plugins excluded from All tab and present in Disabled tab, assert Outdated tab filters on `behind`.
- A `Makefile` target `test`: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"`.

Manual verification checklist (for anything not practically unit-testable, e.g. actual git network fetch): open `:Packui` against a real plugin set, exercise every keymap in the table above once.
