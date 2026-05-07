--- Quick-edit: visual select → prompt → edit via main session with isolated region

local session = require("lg.session.session")
local spinners = require("lg.spinner.spinners")

local M = {}

local paint_ns = vim.api.nvim_create_namespace("lg.ui.paint")

local function highlight(bufnr, start_line, end_line)
	local signs = require("lg.ui.signs")
	for row = start_line - 1, end_line - 1 do
		vim.api.nvim_buf_set_extmark(bufnr, paint_ns, row, 0, {
			end_line = row + 1, hl_group = "LgPaintLine", hl_eol = true, priority = 110,
		})
		vim.api.nvim_buf_set_extmark(bufnr, paint_ns, row, 0, {
			sign_text = signs.bracket(row, start_line, end_line),
			sign_hl_group = "LgPaintSign",
			priority = 110,
		})
	end
end

local function clear_highlight(bufnr, start_line, end_line)
	local marks = vim.api.nvim_buf_get_extmarks(bufnr, paint_ns, { start_line - 1, 0 }, { end_line - 1, -1 }, {})
	for _, mark in ipairs(marks) do
		vim.api.nvim_buf_del_extmark(bufnr, paint_ns, mark[1])
	end
end

function M.quick_edit()
	local buf = vim.api.nvim_get_current_buf()
	local start_line = vim.fn.getpos("'<")[2]
	local end_line = vim.fn.getpos("'>")[2]
	local file = vim.api.nvim_buf_get_name(buf)
	local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)

	highlight(buf, start_line, end_line)

	local region = {
		bufnr = buf,
		file = file,
		start_line = start_line,
		end_line = end_line,
		lines = lines,
	}

	require("lg.ui.prompt").open(function(prompt, flags)
		if not prompt or prompt == "" then
			clear_highlight(buf, start_line, end_line)
			return
		end

		if flags.has_lsp then
			local info = require("lg.tools.lsp").gather(buf, start_line, end_line)
			if info ~= "" then prompt = prompt .. "\n\nLSP Information:\n" .. info end
		end

		local spin = spinners.start({ region })
		session.send_oneshot(prompt, { region }, {}, function()
			vim.schedule(function()
				spin:stop()
				clear_highlight(buf, start_line, end_line)
			end)
		end)
	end, function()
		clear_highlight(buf, start_line, end_line)
	end)
end

return M
