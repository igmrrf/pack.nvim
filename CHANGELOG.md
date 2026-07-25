# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Added
- Native Neovim 0.12+ `vim.pack` integration.
- Lazy-loading by events, filetypes, commands, and keymaps.
- Floating dashboard for updates, logs, and profiling.
- Persistent disable state.
- Build hooks support.
- MIT License.
- Documentation `doc/pack.txt`.
- `092ab05`: Automatically migrate plugins between opt and start when lazy flag changes.
- `7b2d6d0`: Add keys lazy-load trigger, `map_keys` helper, and fix packpath bug.
- `5e9dccb`: Add `opts`/`main` shorthand to skip writing a config function.
- `e9cd65a`: Add persisted disabled-plugin JSON store.
- `6adc04d`: Track disabled/behind state and persist disabled flag.
- `cbdc2a0`: Add git-fetch based outdated-plugin detection.
- `ce23dbe`: Add dashboard help popup (`?`).
- `ce35962`: Add quick/full plugin details popups, move logs to `l`.
- `c2d6d64`: Add All/Outdated/Disabled dashboard tabs.
- `3946e42`: Add disable/enable toggle (`x`) to dashboard.
- `59bbac1`: Rich per-plugin outdated display, recheck (`c`) and update keymaps (`u`/`U`).
- `bea5860`: Implement lockfile and `nvim-pack-extra` json schema.
- `fabf7f5`: Adopt advanced declarative spec features inspired by `zpack.nvim`.
- `c82d993`: Add native vim pack bootstrap and all features spec examples.
- `ea96aa0`: Add single shared loading spinner and in-flight update state.
- `a2c0b4e`: Preserve `pack.nvim` metadata on native-style (`src=`) specs.
- `202eca8`: Add health checks, helptags generation, and CI setup.

### Changed
- Refactored entire codebase to delegate cloning and locking to `vim.pack`.
- Refactored asynchronous operations for checking updates.

### Fixed
- Fixed bug where a failed network fetch would mark a plugin as errored and disable lazy triggers.
- Made test suite hermetic to avoid cross-test `ftdetect` cache collisions.
- Added fallback for `fs_rename` on Windows.
