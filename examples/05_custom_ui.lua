require("pack").setup({
  ui = {
    -- Change the border style of the floating window
    -- Options: "single", "double", "rounded", "solid", "shadow"
    border = "double", 
    
    -- Customize the icons used in the dashboard
    icons = {
      loaded = "🟢",
      not_loaded = "⚪",
      error = "🔴",
      sync = "🔄"
    }
  },
  plugins = {
    { "igmrrf/pack.nvim" }
  }
})
