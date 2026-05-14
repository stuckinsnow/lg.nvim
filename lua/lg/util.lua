local M = {}

--- Find the first window with a normal (editor) buffer in the current tab.
--- @return integer|nil
function M.find_editor_win()
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		local b = vim.api.nvim_win_get_buf(win)
		if vim.bo[b].buftype == "" then return win end
	end
end

return M
