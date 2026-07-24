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

### Changed
- Refactored entire codebase to delegate cloning and locking to `vim.pack`.
- Refactored asynchronous operations for checking updates.

### Fixed
- Fixed bug where a failed network fetch would mark a plugin as errored and disable lazy triggers.
- Made test suite hermetic to avoid cross-test `ftdetect` cache collisions.
- Added fallback for `fs_rename` on Windows.
