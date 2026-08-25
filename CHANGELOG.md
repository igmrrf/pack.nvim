# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.5] - 2026-08-25
### Added

- Dashboard "Queued" status/group: plugins targeted for install or update now show as queued until a worker slot actually starts their transfer, instead of the whole batch appearing "installing"/"updating" at once behind the concurrency limit.
- Background installs (`use_git = true`) now run through the same bounded concurrent pump as background updates, significantly speeding up bulk clones of many missing plugins at once.

### Fixed

- A plugin pinned with a lazy.nvim-style `version` range (e.g. `version = "*"`) whose repo has no tagged releases no longer fails installation with "No versions fit constraint"; pack.nvim retries without the version constraint and tracks the default branch instead, isolating the retry to only the offending plugin in a batch.
- Background installs no longer call native `vim.pack.add` after a successful clone (it would look up a lockfile entry it doesn't have cached yet and try to re-clone); the plugin now loads directly for the session and native adopts it from the lockfile on the next startup.
- Concurrent background clones could clobber each other's lockfile entry when a blocking `git rev-parse HEAD` call interleaved with another clone's write; lockfile writes are now serialized.
- `:Pack update`/`U`/`S` no longer re-targets a plugin that is already mid-install or mid-update, which previously could clobber its in-flight status.
- A failed load after a successful background clone is now reported and marks the plugin as errored instead of leaving it silently stuck at "installing".

## [0.1.4] - 2026-08-25
### Added

- `use_git` config (boolean, default `false`): installs and updates run through backgrounded `git` (`vim.system`) instead of native vim.pack's blocking progress jobs, keeping the UI responsive during large transfers. Native `vim.pack.add`/`update` still runs afterwards - cheaply, with objects already local - to register plugins and reconcile the lockfile. Pinned specs (tag/commit/version ranges) keep the direct native path.
- Bulk update flows (`U`, `S`, `:Pack sync`, `:Pack update`) now batch targets at a **maximum of 5 plugin names per native call** (12 targets -> 5+5+2), so no single progress job stalls on a huge transfer.
- `:Pack update` accepts any number of plugin names in one call (e.g. `:Pack update foo.nvim bar.nvim`). Targets are validated first (unknown names are reported and skipped), then delegated to the same batched updater the dashboard uses - including `use_git` background transfers and a single aggregated native reconciliation pass. Tab completion now works for every target position.
- Specs that set both `ft` and `keys`: the keymaps adhere to the filetype trigger and are never bound globally — the lazy-load placeholder and the post-load real mapping exist only buffer-locally in buffers with a matching filetype.

### Fixed

- A failed background clone now removes its half-written target directory instead of leaving debris that made the next startup treat the plugin as installed.
- Version strings handed to `git clone --branch` can no longer start with `-` (argument-injection hardening); hex-like versions (7+ chars) are treated as commit SHAs rather than refs.

## [0.1.3] - 2026-08-13
### Changed

- Plugin registration now de-duplicates by URL to gracefully merge explicitly named plugins with implicit dependency specifications.
- The `Sync` (`S`) dashboard action and `:Pack sync` command now exclusively update plugins known to be outdated (`behind > 0`), rather than attempting to redundantly update all non-missing plugins.

### Fixed
- Fixed an issue where `config = true` crashed during initialization. It now correctly falls back to invoking the `setup` function parameter-less, maintaining equivalence to `opts = {}`.
- Fixed dashboard duplication for `.nvim` suffixed packages caused by implicit dependency entries taking precedence over renamed explicit config specs.

## [0.1.2] - 2026-08-10
### Changed
- Upgraded the automated release workflow to cleanly parse the changelog without syntax errors on standard runner environments.

### Fixed
- Updated tests to accurately reflect the new UI behavior where details blocks completely close upon completion of background plugin tasks.

## [0.1.1] - 2026-08-10
### Added
- `.luarc.json` configuration file for Neovim lua development.

### Changed
- Refactored plugin installation and updates to process asynchronously, significantly preventing Neovim from freezing when processing numerous plugins.
- Modernized internal file path and iteration logic utilizing Neovim 0.10+ standard libraries (`vim.fs.joinpath`, `vim.fs.find`, `vim.iter`).

### Fixed
- Fixed synchronous recovery mechanism in update routines and ensured tests run properly in a headless mode by falling back to synchronous execution.
- Automatically close opened logs/detail views for a plugin when its update or installation finishes.

## [0.1.0] - 2026-08-02
### Added
- Native Neovim 0.12+ `vim.pack` integration and bootstrap mechanism.
- Lazy-loading triggers via events, filetypes, commands, and keymaps.
- Floating dashboard for updates, logs, and profiling.
- Persistent disabled-plugin state and JSON store.
- Build hooks support.
- Support for dual-style tracking: manage both declarative specs and unknown adopted native plugins.
- Tools to upgrade adopted plugin stubs into fully managed plugins.
- Pending updates diff viewer, advanced filtering, and load-time visualization.
- Multi-select support in the dashboard with checkboxes, contextual top key bar, and updated tab styling.
- Lockfile implementation and `nvim-pack-extra` JSON schema.
- Git-fetch based outdated-plugin detection and rich per-plugin outdated display.
- Single shared loading spinner and in-flight update states.
- Auto-migration of plugins between `opt` and `start` directories when the lazy flag changes.
- `opts`/`main` shorthand to skip writing explicit config functions.
- `auto_open` and `silent` configuration options for startup behavior.
- Quick/full plugin details popups and help popups.
- Real-time build status display in the Outdated tab, holding the "behind" state until the build finishes.
- Non-interactive sync API and live log streaming.
- Auto-positioning of the cursor on the first plugin when opening the dashboard.
- Enhanced UX with auto-switching details and auto-closing on specific actions.
- `pack.status()`, `pack.stats()`, and `pack.picker()` APIs.
- `:Pack picker` subcommand for quick navigation to plugin directories via `snacks.picker` or `vim.ui.select`.
- Built-in Lualine statusline extension (`lualine/extensions/pack.lua`).
- Default custom highlight groups (`PackHeader`, `PackPluginName`, `PackStatusOk`, etc.).

### Changed
- Refactored the entire codebase into focused, modular submodules.
- Refactored asynchronous operations for checking updates.
- Refined dashboard layout, tab navigation (All/Outdated/Disabled), and action keymaps.
- Reset plugins on initialization to restore isolation and allow for safe re-initialization.
- Setup now registers declarative specs additively so wrapper-added plugins survive.
- Resolved `default_main` evaluation by probing the plugin's `lua/` directory.

### Fixed
- Fixed issue where a failed network fetch would mark a plugin as errored and disable lazy triggers.
- Inferred `lazy = true` automatically when `event`, `ft`, `cmd`, or `keys` are defined without an explicit flag.
- Prevented infinite recursion when lazy plugins require their own module during `packadd`.
- Ensured keys are properly rebound regardless of which path loaded the plugin.
- Fixed dependency stubs improperly shadowing full plugin specifications by relying on native active flags.
- Fixed `plugin_at_cursor` scope error and preserved cursor position during updates.
- Improved cleanup and uninstallation of unmanaged plugins using `vim.pack.del`.
- Ensured plugin commands are sourced before executing ex-command build hooks.
- Reflected build hook failures accurately in the overall plugin status.
- Addressed `nvim_buf_set_lines` rejections by ensuring detail lines are strictly newline-free.
- Stabilized UI cleanup routines and fortified test isolation for a hermetic test suite.
- Whitelisted `vim.keymap.set` opts fields on keys entries.
- Added fallback for `fs_rename` on Windows.
- Addressed immutability issues during setup, re-entrancy bugs, and improved health checks.
- Sanitized native spec data and properly batched plugin installations.

### Documentation
- Added MIT License and `doc/pack.txt`.
- Added open-source community guidelines, templates, license, and security policies.
- Streamlined the README, adding a comprehensive plugin spec and API reference section.
- Migrated the comparison matrix directly into the README.
- Synchronized dashboard keymap documentation to reflect 1:1 with the actual implementation.
- Updated README image URLs to point directly to reliable media links.
- Documented limitations when mixing tracking styles and clarified the first-writer-wins strategy.
- Added all features spec examples.
