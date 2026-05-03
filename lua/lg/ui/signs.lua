--- Shared sign-column bracket helpers
local M = {}

--- Get the bracket sign character for a row in a range
--- @param row number 0-based row
--- @param start_line number 1-based start
--- @param end_line number 1-based end
--- @return string
function M.bracket(row, start_line, end_line)
	local total = end_line - start_line + 1
	if total == 1 then return "│" end
	if row == start_line - 1 then return "┌" end
	if row == end_line - 1 then return "└" end
	return "│"
end

--- Place bracket signs on a range
--- @param bufnr number
--- @param ns number namespace
--- @param start_line number 1-based
--- @param end_line number 1-based
--- @param hl_group string sign highlight group
--- @param priority? number default 110
function M.place(bufnr, ns, start_line, end_line, hl_group, priority)
	priority = priority or 110
	for row = start_line - 1, end_line - 1 do
		pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, {
			sign_text = M.bracket(row, start_line, end_line),
			sign_hl_group = hl_group,
			priority = priority,
		})
	end
end

return M
