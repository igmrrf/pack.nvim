---
name: Bug Report
about: Create a report to help us improve pack.nvim
title: 'bug: '
labels: 'bug'
assignees: ''
---

**Describe the Bug**
A clear and concise description of what the bug is.

**Environment Information**
- Neovim version (`nvim --version`):
- Operating System:
- `pack.nvim` commit / version:

**Minimal Configuration**
Please provide a minimal `init.lua` snippet to reproduce the issue:

```lua
vim.pack.add({ { src = "https://github.com/igmrrf/pack.nvim" } })
require("pack").setup({
  plugins = {
    -- Reproducible plugin spec here
  }
})
```

**Steps to Reproduce**
1. Open Neovim with `nvim -u minimal_init.lua`
2. Run command `...`
3. See error

**Expected Behavior**
A clear and concise description of what you expected to happen.

**Log & Traceback Output**
If applicable, paste error messages or log output from `:Pack` dashboard / `:messages`.
