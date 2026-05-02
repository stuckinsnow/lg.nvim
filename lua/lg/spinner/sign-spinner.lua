--- Sign spinner: cycles all paint signs through color gradient in unison

local M = {}

local paint_ns = vim.api.nvim_create_namespace("lg.ui.paint")

local hls = { "LgPulse1", "LgPulse2", "LgPulse3", "LgPulse4", "LgPulse5", "LgPulse6", "LgPulse7", "LgPulse8" }

function M.render_region(bufnr, _, start_line, end_line, tick)
	local hi = hls[(tick % #hls) + 1]
	local marks = vim.api.nvim_buf_get_extmarks(bufnr, paint_ns, { start_line - 1, 0 }, { end_line - 1, -1 }, { details = true })
	for _, mark in ipairs(marks) do
		local id, row, _, details = mark[1], mark[2], mark[3], mark[4]
		if details.sign_text then
			pcall(vim.api.nvim_buf_set_extmark, bufnr, paint_ns, row, 0, {
				id = id,
				sign_text = details.sign_text,
				sign_hl_group = hi,
				priority = 110,
			})
		end
	end
end

return M
