# `pack.nvim` Examples

This directory contains full configuration examples demonstrating different ways to integrate and utilize `pack.nvim`.

## Files
- [01_basic_bootstrap.lua](./01_basic_bootstrap.lua): The minimal, zero-to-hero snippet you can copy/paste into your `init.lua` to let `pack.nvim` bootstrap itself and install your first plugins.
- [02_lazy_loading.lua](./02_lazy_loading.lua): A comprehensive guide to delaying plugin loads to achieve lightning-fast startup times using commands, events, filetypes, and keymaps.
- [03_advanced_hooks.lua](./03_advanced_hooks.lua): Examples of declaring dependencies, running post-install build scripts (like `make`), and loading local plugins from disk.
- [04_adopting_vim_pack.lua](./04_adopting_vim_pack.lua): Demonstrates how to use `pack.nvim` as a transparent wrapper to instantly modernize an existing native `vim.pack.add` configuration.
- [05_custom_ui.lua](./05_custom_ui.lua): Shows how to override the dashboard aesthetics with custom borders and icons.
