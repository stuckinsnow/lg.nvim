--- Quick-edit: visual select → prompt → edit via main session with isolated region

local session = require("lg.session")
local spinners = require("lg.spinners")

local M = {}

local ns = vim.api.nvim_create_namespace("lg_quick_paint")

local function highlight(bufnr, start_line, end_line)
	for row = start_line - 1, end_line - 1 do
		vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
			end_line = row + 1, hl_group = "LgPaintLine", hl_eol = true, priority = 120,
		})
	end
end

local function clear_highlight(bufnr)
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
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

	require("lg.prompt").open(function(prompt, has_lsp)
		if not prompt or prompt == "" then
			clear_highlight(buf)
			return
		end

		if has_lsp then
			local info = require("lg.lsp").gather(buf, start_line, end_line)
			if info ~= "" then prompt = prompt .. "\n\nLSP Information:\n" .. info end
		end

		local spin = spinners.start({ region })
		session.send_oneshot(prompt, { region }, {}, function()
			vim.schedule(function()
				spin:stop()
				clear_highlight(buf)
			end)
		end)
	end, function()
		clear_highlight(buf)
	end)
end

return M
