--- Prompt: floating input buffer for multi-line prompts

local M = {}

--- @class PromptFlags
--- @field has_file_lsp boolean
--- @field has_lsp boolean
--- @field has_tsc boolean
--- @field has_diag boolean
--- @field has_search boolean
--- @field has_auto_paint boolean
--- @field has_git boolean
--- @field has_devlens boolean
--- @field has_hint boolean
--- @field has_sub boolean
--- @field has_suggest boolean
--- @field has_ask boolean

--- Open a floating buffer for prompt input, call cb(text, flags) on submit
--- @param cb fun(text: string, flags: PromptFlags)
--- @param on_cancel? fun()
function M.open(cb, on_cancel)
	local ctx_pct = require("lg.ui.window").get_context_pct()
	if ctx_pct then require("lg.kitty").set(ctx_pct) end
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
		require("lg.kitty").clear()
		if text ~= "" then
			cb(text, {
				has_file_lsp = text:match("@FILE_LSP") ~= nil,
				has_lsp = text:match("@LSP") ~= nil and not text:match("@FILE_LSP"),
				has_tsc = text:match("@TSC") ~= nil,
				has_diag = text:match("@DIAG") ~= nil,
				has_search = text:match("@SEARCH") ~= nil,
				has_auto_paint = text:match("@INFO") ~= nil,
				has_git = text:match("@GIT") ~= nil,
				has_devlens = text:match("@DEVLENS") ~= nil,
				has_hint = text:match("@HINT") ~= nil,
				has_sub = text:match("@SUB") ~= nil,
				has_suggest = text:match("@SUGGEST") ~= nil,
				has_help = text:match("@HELP") ~= nil,
				has_ask = text:match("@ASK") ~= nil,
			})
		end
	end

	local function cancel()
		vim.api.nvim_win_close(win, true)
		vim.api.nvim_buf_delete(buf, { force = true })
		require("lg.kitty").clear()
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
