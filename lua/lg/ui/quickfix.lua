--- Quickfix list helpers for lg-hint LSP diagnostics (hints, suggestions, annotations)

local M = {}

local severity_map = { "E", "W", "I", "N" }

--- Snapshot all diagnostics published by the lg-hint LSP.
--- @return vim.Diagnostic[]
function M.diagnostics()
	local out = {}
	for _, client in ipairs(vim.lsp.get_clients({ name = "lg-hint" })) do
		local ns = vim.lsp.diagnostic.get_namespace(client.id, false)
		if ns then
			for _, d in ipairs(vim.diagnostic.get(nil, { namespace = ns })) do
				out[#out + 1] = d
			end
		end
	end
	return out
end

--- Count diagnostics published by the lg-hint LSP.
--- @return integer
function M.count()
	local n = 0
	for _, client in ipairs(vim.lsp.get_clients({ name = "lg-hint" })) do
		local ns = vim.lsp.diagnostic.get_namespace(client.id, false)
		if ns then
			n = n + #vim.diagnostic.get(nil, { namespace = ns })
		end
	end
	return n
end

local function diag_key(d)
	return table.concat({ d.bufnr, d.lnum, d.col, d.message }, "\0")
end

--- Snapshot keys of currently published lg-hint diagnostics.
--- @return table<string, boolean>
function M.snapshot()
	local keys = {}
	for _, d in ipairs(M.diagnostics()) do
		keys[diag_key(d)] = true
	end
	return keys
end

--- Count diagnostics published since `before_keys`.
--- @param before_keys table<string, boolean>
--- @return integer
function M.count_new(before_keys)
	local n = 0
	for _, d in ipairs(M.diagnostics()) do
		if not before_keys[diag_key(d)] then
			n = n + 1
		end
	end
	return n
end

--- Put diagnostics published since `before_keys` (or all if nil) into the quickfix list.
--- @param before_keys? table<string, boolean>
--- @param title? string
--- @return integer count
function M.populate(before_keys, title)
	local items = {}
	for _, d in ipairs(M.diagnostics()) do
		if not before_keys or not before_keys[diag_key(d)] then
			items[#items + 1] = {
				bufnr = d.bufnr,
				lnum = d.lnum + 1,
				col = d.col + 1,
				end_lnum = d.end_lnum and (d.end_lnum + 1) or nil,
				end_col = d.end_col and (d.end_col + 1) or nil,
				text = "AI - " .. d.message,
				type = severity_map[d.severity] or "I",
			}
		end
	end
	table.sort(items, function(a, b)
		local fa, fb = vim.api.nvim_buf_get_name(a.bufnr), vim.api.nvim_buf_get_name(b.bufnr)
		if fa ~= fb then
			return fa < fb
		end
		return a.lnum < b.lnum
	end)
	if #items > 0 then
		vim.fn.setqflist({}, " ", { title = title or "lg annotations", items = items })
	end
	return #items
end

return M
