local state = require("pack.state")
local pack = require("pack")
local commands = require("pack.commands")

describe("pack status, stats, picker, and lualine extension", function()
	before_each(function()
		state.init({
			plugins = {
				{ "user/loaded_plug.nvim" },
				{ "user/opt_plug.nvim" },
				{ "user/disabled_plug.nvim" },
			},
		})
		-- Set loaded_plug.nvim status to "loaded"
		state.update_status("loaded_plug.nvim", "loaded")
		-- Mark disabled_plug.nvim as disabled
		state.set_disabled("disabled_plug.nvim", true)
	end)

	it("pack.status() reports correct count of total, loaded, and disabled plugins", function()
		local st = pack.status()
		assert.equals(3, st.total)
		assert.equals(1, st.loaded)
		assert.equals(1, st.disabled)
	end)

	it("pack.stats() formats loaded/total count string", function()
		local stats = pack.stats()
		assert.equals("📦 1/3 loaded", stats)
	end)

	it("pack.picker() falls back to vim.ui.select when snacks is unavailable", function()
		local called = false
		local select_items = nil
		local orig_select = vim.ui.select
		vim.ui.select = function(items, opts, on_choice)
			called = true
			select_items = items
		end

		pack.picker()

		vim.ui.select = orig_select
		assert.is_true(called, "vim.ui.select should be called")
		assert.equals(3, #select_items)
		assert.equals("disabled_plug.nvim", select_items[1].name)
		assert.equals("loaded_plug.nvim", select_items[2].name)
		assert.equals("opt_plug.nvim", select_items[3].name)
	end)

	it(":Pack picker subcommand invokes pack.picker()", function()
		local called = false
		local orig_picker = pack.picker
		pack.picker = function()
			called = true
		end

		commands.setup_user_command(pack)
		vim.cmd("Pack picker")

		pack.picker = orig_picker
		assert.is_true(called, ":Pack picker should invoke pack.picker")
	end)

	it("lualine extension renders pack status", function()
		local ext = require("lualine.extensions.pack")
		assert.equals("pack", ext.filetypes[1])
		assert.equals("📦 PACK", ext.sections.lualine_a[1]())
		assert.equals("1/3 loaded", ext.sections.lualine_b[1]())
	end)
end)
