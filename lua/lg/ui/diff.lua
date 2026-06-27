--- AI edit application with gutter markers
--- Markers auto-clear when you edit those lines

local M = {}

local ns = vim.api.nvim_create_namespace("lg_marks")
local attached_bufs = {}

local function ensure_highlights()
	vim.api.nvim_set_hl(0, "LgSign", { fg = "#e5c07b", default = true })
	vim.api.nvim_set_hl(0, "LgLine", { bg = "#2a2a3a", default = true })
end

local function attach_listener(bufnr)
	if attached_bufs[bufnr] then
		return
	end
	attached_bufs[bufnr] = true

	vim.api.nvim_buf_attach(bufnr, false, {
		on_lines = function(_, buf, _, first, last_old, _)
			local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { first, 0 }, { last_old - 1, -1 }, {})
			for _, m in ipairs(marks) do
				vim.api.nvim_buf_del_extmark(buf, ns, m[1])
			end
		end,
	})
end

--- @param bufnr number
--- @param start_row number 0-indexed
--- @param end_row number 0-indexed exclusive
--- @param new_lines string[]
function M.apply(bufnr, start_row, end_row, new_lines)
	-- Clear paint signs in this region before editing (prevents displacement)
	local paint_ns = vim.api.nvim_create_namespace("lg.ui.paint")
	pcall(vim.api.nvim_buf_clear_namespace, bufnr, paint_ns, start_row, end_row)
	vim.api.nvim_buf_set_lines(bufnr, start_row, end_row, false, new_lines)
	ensure_highlights()
	attach_listener(bufnr)
	local signs = require("lg.ui.signs")
	local last = start_row + #new_lines - 1
	for i = start_row, last do
		vim.api.nvim_buf_set_extmark(bufnr, ns, i, 0, {
			sign_text = signs.bracket(i, start_row + 1, last + 1),
			sign_hl_group = "LgSign",
			line_hl_group = "LgLine",
			priority = 100,
		})
	end
end

--- Apply multiple region edits atomically. Sorts bottom-up internally.
--- @param regions { bufnr: number, start_line: number, end_line: number }[]
--- @param edits { region_id: number, new_code: string }[]
function M.apply_all(regions, edits)
	local sorted = {}
	for _, e in ipairs(edits) do
		local r = regions[e.region_id + 1]
		if r and vim.api.nvim_buf_is_valid(r.bufnr) then
			table.insert(sorted, { region = r, new_lines = vim.split(e.new_code:gsub("\n$", ""), "\n") })
		end
	end
	table.sort(sorted, function(a, b)
		return a.region.start_line > b.region.start_line
	end)
	for _, entry in ipairs(sorted) do
		M.apply(entry.region.bufnr, entry.region.start_line - 1, entry.region.end_line, entry.new_lines)
	end
end

--- @param bufnr? number defaults to all tracked buffers
function M.clear(bufnr)
	if bufnr then
		vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
		return
	end
	for buf, _ in pairs(attached_bufs) do
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
		end
	end
	local cur = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_clear_namespace(cur, ns, 0, -1)
end

return M
