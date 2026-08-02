local M = {}

M.sections = {
	lualine_a = {
		function()
			return "📦 PACK"
		end,
	},
	lualine_b = {
		function()
			local ok, pack = pcall(require, "pack")
			if ok and pack.status then
				local st = pack.status()
				return string.format("%d/%d loaded", st.loaded, st.total)
			end
			return "Plugin Manager"
		end,
	},
	lualine_z = { "location" },
}

M.filetypes = { "pack" }

return M
