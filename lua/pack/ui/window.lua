local M = {}

function M.create_window(config, update_ui_cb)
	local buf_id = vim.api.nvim_create_buf(false, true)
	vim.bo[buf_id].bufhidden = "wipe"
	vim.bo[buf_id].buftype = "nofile"
	vim.bo[buf_id].swapfile = false
	vim.bo[buf_id].filetype = "pack"

	local width = math.floor(vim.o.columns * 0.8)
	local height = math.floor(vim.o.lines * 0.8)

	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local win_id = vim.api.nvim_open_win(buf_id, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		border = config.ui.border,
		title = " Pack.nvim ",
		title_pos = "center",
		style = "minimal",
	})

	if vim.v.vim_did_enter == 0 then
		vim.api.nvim_create_autocmd("VimEnter", {
			group = vim.api.nvim_create_augroup("pack_ui_startup_focus", { clear = true }),
			once = true,
			callback = function()
				if win_id and vim.api.nvim_win_is_valid(win_id) then
					vim.api.nvim_set_current_win(win_id)
				end
			end,
		})
	else
		vim.schedule(function()
			if win_id and vim.api.nvim_win_is_valid(win_id) then
				vim.api.nvim_set_current_win(win_id)
			end
		end)
	end

	vim.api.nvim_create_autocmd("VimResized", {
		group = vim.api.nvim_create_augroup("pack_ui_resize", { clear = true }),
		callback = function()
			if not win_id or not vim.api.nvim_win_is_valid(win_id) then
				return true
			end
			local w = math.floor(vim.o.columns * 0.8)
			local h = math.floor(vim.o.lines * 0.8)
			vim.api.nvim_win_set_config(win_id, {
				relative = "editor",
				width = w,
				height = h,
				row = math.floor((vim.o.lines - h) / 2),
				col = math.floor((vim.o.columns - w) / 2),
				title = " Pack.nvim ",
				title_pos = "center",
			})
			update_ui_cb()
		end,
	})

	local opts = { buffer = buf_id, noremap = true, silent = true, nowait = true }
	vim.keymap.set("n", "q", "<Cmd>close<CR>", opts)
	vim.keymap.set("n", "g?", "<Cmd>lua require('pack.ui').show_help()<CR>", opts)
	vim.keymap.set("n", "S", "<Cmd>Pack sync<CR>", opts)
	vim.keymap.set("n", "C", "<Cmd>lua require('pack.ui').clean()<CR>", opts)
	vim.keymap.set("n", "X", "<Cmd>lua require('pack.ui').uninstall()<CR>", opts)
	vim.keymap.set("n", "<Space>", "<Cmd>lua require('pack.ui').toggle_select()<CR>", opts)
	vim.keymap.set("n", "v", "<Cmd>lua require('pack.ui').clear_select()<CR>", opts)
	vim.keymap.set("n", "<CR>", "<Cmd>lua require('pack.ui').toggle_details()<CR>", opts)
	vim.keymap.set("n", "K", "<Cmd>lua require('pack.ui').show_full_details()<CR>", opts)
	vim.keymap.set("n", "l", "<Cmd>lua require('pack.ui').show_log()<CR>", opts)
	vim.keymap.set("n", "p", "<Cmd>lua require('pack.ui').show_profile()<CR>", opts)
	vim.keymap.set("n", "d", "<Cmd>lua require('pack.async').show_diff()<CR>", opts)
	vim.keymap.set("n", "<Tab>", "<Cmd>lua require('pack.ui').cycle_tab()<CR>", opts)
	vim.keymap.set("n", "x", "<Cmd>lua require('pack.ui').toggle_disabled()<CR>", opts)
	vim.keymap.set("n", "c", "<Cmd>lua require('pack.async').check_all_outdated()<CR>", opts)
	vim.keymap.set("n", "u", "<Cmd>lua require('pack.ui').update_one()<CR>", opts)
	vim.keymap.set("n", "U", "<Cmd>lua require('pack.ui').update_all_outdated()<CR>", opts)
	vim.keymap.set("n", "/", "<Cmd>lua require('pack.ui').filter()<CR>", opts)
	vim.keymap.set("n", "1", "<Cmd>lua require('pack.ui').set_tab(1)<CR>", opts)
	vim.keymap.set("n", "2", "<Cmd>lua require('pack.ui').set_tab(2)<CR>", opts)
	vim.keymap.set("n", "3", "<Cmd>lua require('pack.ui').set_tab(3)<CR>", opts)

	return buf_id, win_id
end

return M
