--- Prompt: floating input buffer for multi-line prompts

local M = {}

--- Open a floating buffer for prompt input, call cb(text) on submit
--- @param cb fun(text: string, has_lsp: boolean)
--- @param on_cancel? fun()
function M.open(cb, on_cancel)
	local ui = vim.api.nvim_list_uis()[1]
	local width = math.floor(ui.width * 0.6)
	local height = 8

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].filetype = "markdown"
	vim.diagnostic.enable(false, { bufnr = buf })

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((ui.height - height) / 2),
		col = math.floor((ui.width - width) / 2),
		style = "minimal",
		border = "rounded",
		title = " lg prompt (ctrl-s to send, q/esc to cancel) ",
		title_pos = "center",
	})

	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	vim.cmd("startinsert")

	local function submit()
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local text = vim.trim(table.concat(lines, "\n"))
		vim.cmd("stopinsert")
		vim.api.nvim_win_close(win, true)
		vim.api.nvim_buf_delete(buf, { force = true })
		if text ~= "" then
			local has_lsp = text:match("@LSP") ~= nil
			local has_tsc = text:match("@TSC") ~= nil
			local has_diag = text:match("@DIAG") ~= nil
			local has_search = text:match("@SEARCH") ~= nil
			local has_auto_paint = text:match("@INFO") ~= nil
			local has_git = text:match("@GIT") ~= nil
			local has_hint = text:match("@HINT") ~= nil
			local has_sub = text:match("@SUB") ~= nil
			local has_suggest = text:match("@SUGGEST") ~= nil
			cb(text, has_lsp, has_tsc, has_diag, has_search, has_auto_paint, has_git, has_hint, has_sub, has_suggest)
		end
	end

	local function cancel()
		vim.api.nvim_win_close(win, true)
		vim.api.nvim_buf_delete(buf, { force = true })
		if on_cancel then
			on_cancel()
		end
	end

	vim.keymap.set("n", "q", cancel, { buffer = buf })
	vim.keymap.set("n", "<Esc>", cancel, { buffer = buf })
	vim.keymap.set("n", "<CR>", submit, { buffer = buf })
	vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = buf })
end

return M
