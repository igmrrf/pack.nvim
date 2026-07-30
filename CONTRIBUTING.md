# Contributing to `pack.nvim`

Thank you for your interest in contributing to `pack.nvim`! We welcome bug reports, feature requests, documentation improvements, and code contributions.

---

## 📋 Table of Contents
- [Development Setup](#-development-setup)
- [Running Tests](#-running-tests)
- [Code Architecture & Guidelines](#-code-architecture--guidelines)
- [Submitting a Pull Request](#-submitting-a-pull-request)
- [Reporting Issues](#-reporting-issues)

---

## 🛠 Development Setup

1. **Fork and Clone the Repository**:
   ```bash
   git clone https://github.com/<your-username>/pack.nvim.git
   cd pack.nvim
   ```

2. **Test Environment Requirements**:
   - **Neovim**: `>= 0.12.0` (with native `vim.pack` support)
   - **Git**: `>= 2.30.0`
   - **Plenary.nvim**: Required for running the test suite (automatically handled by the test harness).

3. **Symlink / Add to Neovim Runtimepath**:
   To test your local changes inside your Neovim setup, prepend the repository path in your `init.lua`:
   ```lua
   vim.opt.rtp:prepend("/path/to/your/local/pack.nvim")
   ```

---

## 🧪 Running Tests

`pack.nvim` relies on plenary.nvim's `busted` test runner.

To run the entire test suite headlessly:

```bash
make test
```

Or run an individual test spec:

```bash
nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/ui_spec.lua"
```

> **Note**: All PRs must pass `make test` cleanly with 0 failures and 0 errors.

---

## 📐 Code Architecture & Guidelines

- **File Size Constraint**: To maintain high modularity, every file in `lua/pack/` **must remain under 300 lines of code**. If a module grows beyond 300 lines, extract cohesive sub-responsibilities into submodules under `lua/pack/ui/`, `lua/pack/state/`, `lua/pack/loader/`, or `lua/pack/async/`.
- **Neovim API Usage**: Use standard Neovim Lua APIs (`vim.api.*`, `vim.fn.*`, `vim.pack.*`). Avoid heavy external dependencies.
- **Code Style & Formatting**: Format Lua code using `stylua` if available:
  ```bash
  stylua lua/ tests/
  ```
- **Error Handling**: Perform graceful error handling using `pcall` / `xpcall` where external git commands or file operations might fail. Never crash the editor.

---

## 🔀 Submitting a Pull Request

1. **Create a Feature Branch**:
   ```bash
   git checkout -b feat/your-feature-name
   ```
2. **Implement Your Changes & Add Tests**:
   - Write unit/integration specs in `tests/` covering new functionality or bug fixes.
3. **Verify Tests**:
   - Run `make test` to ensure all existing and new specs pass.
4. **Commit Your Changes**:
   - Use conventional commit messages (e.g. `feat(ui): ...`, `fix(state): ...`, `docs: ...`).
5. **Open a PR**:
   - Provide a clear summary of changes, motivation, and test coverage in the PR description.

---

## 🐛 Reporting Issues

- Search existing [Issues](https://github.com/igmrrf/pack.nvim/issues) to ensure your problem or feature request hasn't already been reported.
- When filing a bug report, please include your Neovim version (`nvim --version`), operating system, relevant `pack.nvim` setup config, and log outputs (`:Pack` logs or runtime messages).
