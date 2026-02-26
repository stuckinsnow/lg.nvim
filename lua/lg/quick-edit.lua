--- Quick-edit: visual select → paint → prompt → isolated oneshot session

local paint = require("lg.paint")
local session = require("lg.session")
local window = require("lg.window")
local spinners = require("lg.spinners")

local M = {}

function M.quick_edit()
	local buf = vim.api.nvim_get_current_buf()
	local start_line = vim.fn.getpos("'<")[2]
	local end_line = vim.fn.getpos("'>")[2]
	paint.add(buf, start_line, end_line)
	window.refresh()

	local regions = { paint.get_all()[#paint.get_all()] }

	require("lg.prompt").open(function(prompt, has_lsp)
		if not prompt or prompt == "" then return end

		if has_lsp then
			local lsp = require("lg.lsp")
			local r = regions[1]
			if vim.api.nvim_buf_is_valid(r.bufnr) then
				local info = lsp.gather(r.bufnr, r.start_line, r.end_line)
				if info ~= "" then
					prompt = prompt .. "\n\nLSP Information:\n" .. info
				end
			end
		end

		spinners.start(regions)
		session.send_oneshot(prompt, regions, {}, function()
			vim.schedule(function()
				spinners.stop()
				paint.clear_last()
				window.refresh()
			end)
		end)
	end)
end

return M
