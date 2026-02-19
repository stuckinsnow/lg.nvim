local M = {}

local ns = vim.api.nvim_create_namespace("lg_auto_paint")

--- @param changes { file: string, line: number }[]
--- @param set_opts? { skip_qf?: boolean }
function M.set(changes, set_opts)
	if not changes or #changes == 0 then return end
	set_opts = set_opts or {}
	local cwd = vim.fn.getcwd() .. "/"
	local items = {}
	for _, e in ipairs(changes) do
		local f = e.file
		if not f:match("^/") then f = cwd .. f end
		if not set_opts.skip_qf then
			table.insert(items, { filename = f, lnum = e.line or 1, text = "AI - Chat", bufnr = 0 })
		end

		-- Apply gutter highlights
		local bufnr = vim.fn.bufnr(f)
		if bufnr == -1 then
			bufnr = vim.fn.bufadd(f)
			vim.fn.bufload(bufnr)
		elseif not vim.api.nvim_buf_is_loaded(bufnr) then
			vim.fn.bufload(bufnr)
		end
		vim.cmd("checktime " .. bufnr)
		local row = math.min(e.line or 1, vim.api.nvim_buf_line_count(bufnr)) - 1
		pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, {
			end_line = row + 1, hl_group = "LgLine", hl_eol = true, priority = 110,
		})
		pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, {
			sign_text = "│", sign_hl_group = "LgSign", priority = 110,
		})
	end
	if #items > 0 then
		vim.fn.setqflist(items, "a")
	end
end

function M.clear()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
		end
	end
	vim.fn.setqflist({}, "r")
end

return M
