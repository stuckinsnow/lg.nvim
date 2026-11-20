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

local function do_redraw(bufnr)
	if vim.api.nvim__redraw then
		local opts = { valid = false, statuscolumn = true, flush = true }
		if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
			opts.buf = bufnr
		end
		pcall(vim.api.nvim__redraw, opts)
	else
		vim.cmd("redraw!")
	end
end

--- Force signcolumn/statuscolumn redraw for a buffer (needed when statuscolumn is set)
--- @param bufnr? number
function M.redraw(bufnr)
	do_redraw(bufnr)
	-- snacks.statuscolumn caches signs/output for `refresh` ms (default 50ms) and
	-- clears the cache on a timer without redrawing. Redraw once more after the
	-- cache expires so new/cleared signs appear without moving the cursor.
	local sc = vim.wo.statuscolumn ~= "" and vim.wo.statuscolumn or vim.o.statuscolumn
	if sc:find("snacks.statuscolumn", 1, true) then
		local delay = 60
		local ok, snacks = pcall(require, "snacks")
		if ok and snacks.config then
			local cfg = snacks.config.get("statuscolumn", { refresh = 50 })
			if cfg and type(cfg.refresh) == "number" then
				delay = cfg.refresh + 10
			end
		end
		vim.defer_fn(function()
			do_redraw(bufnr)
		end, delay)
	end
end

return M
