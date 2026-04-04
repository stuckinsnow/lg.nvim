--- Chat mode: inline diff preview with per-hunk accept/reject
--- Shows proposed changes as virtual text. Does NOT modify the buffer.
--- Accept = write file + ack RPC. Reject = send error response.

local M = {}
local api = vim.api
local dns = api.nvim_create_namespace("lg.ui.hunk")

local hunks = {}

local function hl()
	api.nvim_set_hl(0, "LgHunkOld", { default = true })
	api.nvim_set_hl(0, "LgHunkNew", { default = true })
	api.nvim_set_hl(0, "LgHunkChange", { default = true })
end

-- Find common prefix/suffix lengths between two strings
local function diff_spans(a, b)
	local pre = 0
	while pre < #a and pre < #b and a:byte(pre + 1) == b:byte(pre + 1) do pre = pre + 1 end
	local suf = 0
	while suf < (#a - pre) and suf < (#b - pre) and a:byte(#a - suf) == b:byte(#b - suf) do suf = suf + 1 end
	return pre, suf
end

local function render(h)
	for _, id in ipairs(h.extmark_ids) do pcall(api.nvim_buf_del_extmark, h.bufnr, dns, id) end
	h.extmark_ids = {}

	-- Mark old lines
	for i = 0, #h.old_lines - 1 do
		local row = h.row + i
		if row < api.nvim_buf_line_count(h.bufnr) then
			h.extmark_ids[#h.extmark_ids + 1] = api.nvim_buf_set_extmark(h.bufnr, dns, row, 0, {
				line_hl_group = "LgHunkOld", priority = 100,
			})
		end
	end

	-- Show new lines as virtual text after old lines
	if #h.new_lines > 0 then
		local width = api.nvim_win_get_width(0)
		local virt = {}
		for i, line in ipairs(h.new_lines) do
			local pad = width - #line
			local padded = pad > 0 and (line .. string.rep(" ", pad)) or line
			-- Inline yellow on changed portion
			if h.old_lines[i] and h.old_lines[i] ~= line then
				local pre, suf = diff_spans(h.old_lines[i], line)
				local end_ch = #line - suf
				local changed = end_ch - pre
				if pre > 0 and changed > 0 and changed < #line / 2 and end_ch > pre then
					local chunks = {}
					if pre > 0 then chunks[#chunks + 1] = { padded:sub(1, pre), "LgHunkNew" } end
					chunks[#chunks + 1] = { padded:sub(pre + 1, end_ch), "LgHunkChange" }
					chunks[#chunks + 1] = { padded:sub(end_ch + 1), "LgHunkNew" }
					virt[#virt + 1] = chunks
				else
					virt[#virt + 1] = { { padded, "LgHunkNew" } }
				end
			else
				virt[#virt + 1] = { { padded, "LgHunkNew" } }
			end
		end
		local anchor = math.min(h.row + math.max(#h.old_lines - 1, 0), api.nvim_buf_line_count(h.bufnr) - 1)
		h.extmark_ids[#h.extmark_ids + 1] = api.nvim_buf_set_extmark(h.bufnr, dns, anchor, 0, {
			virt_lines = virt,
		})
	end
end

local function clear_extmarks(h)
	for _, id in ipairs(h.extmark_ids) do pcall(api.nvim_buf_del_extmark, h.bufnr, dns, id) end
	h.extmark_ids = {}
end

local function jump(idx)
	local h = hunks[idx]
	if not h or not api.nvim_buf_is_valid(h.bufnr) then return end
	local win = vim.fn.bufwinid(h.bufnr)
	if win == -1 then
		vim.cmd("buffer " .. h.bufnr)
		win = api.nvim_get_current_win()
	else
		api.nvim_set_current_win(win)
	end
	api.nvim_win_set_cursor(win, { math.min(h.row + 1, api.nvim_buf_line_count(h.bufnr)), 0 })
	vim.cmd("normal! zz")
end

local function resolve(h, accepted, reason)
	if h.on_resolve then
		h.on_resolve(accepted, reason)
		h.on_resolve = nil
		return
	end
	-- Opencode: file already on disk
	if accepted then
		if h.bufnr and api.nvim_buf_is_valid(h.bufnr) then
			vim.bo[h.bufnr].autoread = true
			vim.cmd("checktime " .. h.bufnr)
		end
	else
		-- Revert: write old content back
		if h.path then
			local f = io.open(h.path, "r")
			if f then
				local cur = f:read("*a"); f:close()
				local new_str = table.concat(h.new_lines, "\n")
				local old_str = table.concat(h.old_lines, "\n")
				local s, e = cur:find(new_str, 1, true)
				if s then
					local reverted = cur:sub(1, s - 1) .. old_str .. cur:sub(e + 1)
					local fw = io.open(h.path, "w")
					if fw then fw:write(reverted); fw:close() end
				end
			end
		end
		if h.bufnr and api.nvim_buf_is_valid(h.bufnr) then
			vim.bo[h.bufnr].autoread = true
			vim.cmd("checktime " .. h.bufnr)
			pcall(function() require("gitsigns").reset_buffer() end)
		end
	end
end

local function pending_indices()
	local out = {}
	for i, h in ipairs(hunks) do if h.accepted == nil then out[#out + 1] = i end end
	return out
end

local function nearest()
	local buf = api.nvim_get_current_buf()
	local row = api.nvim_win_get_cursor(0)[1] - 1
	local best, best_dist = nil, math.huge
	for i, h in ipairs(hunks) do
		if h.bufnr == buf and h.accepted == nil then
			local d = math.abs(h.row - row)
			if d < best_dist then best, best_dist = i, d end
		end
	end
	return best
end

-- ── Public ────────────────────────────────────────────────────────

--- Propose a file write for review. Calls on_resolve(accepted) when user decides.
function M.propose_write(path, old_content, new_content, on_resolve)
	local ok = M.propose_edit(path, old_content, new_content)
	if not ok then
		-- Couldn't show diff (e.g. old text not found in buffer) — accept directly
		on_resolve(true)
		return
	end
	-- Attach callback to the last hunk
	hunks[#hunks].on_resolve = on_resolve
end

function M.propose_edit(path, old_text, new_text)
	if type(old_text) ~= "string" or type(new_text) ~= "string" then return false end
	hl()
	local resolved = vim.fn.fnamemodify(path, ":p")

	-- Ensure we're in a normal window
	local win = api.nvim_get_current_win()
	if vim.bo[api.nvim_win_get_buf(win)].buftype ~= "" then
		local found = false
		for _, w in ipairs(api.nvim_list_wins()) do
			if vim.bo[api.nvim_win_get_buf(w)].buftype == "" then
				api.nvim_set_current_win(w); found = true; break
			end
		end
		if not found then vim.cmd("vnew") end
	end

	-- Find or open buffer
	local bufnr
	for _, buf in ipairs(api.nvim_list_bufs()) do
		if api.nvim_buf_is_loaded(buf) then
			local bname = api.nvim_buf_get_name(buf)
			if bname == resolved or bname == path then bufnr = buf; break end
		end
	end
	if bufnr then
		local bwin = vim.fn.bufwinid(bufnr)
		if bwin ~= -1 then
			api.nvim_set_current_win(bwin)
		else
			vim.cmd("buffer " .. bufnr)
		end
	else
		vim.cmd("edit " .. vim.fn.fnameescape(resolved))
		bufnr = api.nvim_get_current_buf()
	end

	-- Find old_text in buffer
	local buf_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local buf_text = table.concat(buf_lines, "\n")
	local s_idx = buf_text:find(old_text, 1, true)
	if not s_idx then
		vim.notify("lg hunk: can't find old_text in " .. path .. " (len=" .. #old_text .. ")", vim.log.levels.WARN)
		return false
	end

	local start_row = select(2, buf_text:sub(1, s_idx - 1):gsub("\n", ""))
	local old_lines = vim.split(old_text, "\n")
	local new_lines = vim.split(new_text, "\n")

	-- Trim matching prefix
	local top = 0
	while top < #old_lines and top < #new_lines and old_lines[top + 1] == new_lines[top + 1] do
		top = top + 1
	end
	-- Trim matching suffix
	local bot = 0
	while bot < (#old_lines - top) and bot < (#new_lines - top)
		and old_lines[#old_lines - bot] == new_lines[#new_lines - bot] do
		bot = bot + 1
	end

	local trimmed_old, trimmed_new = {}, {}
	for i = top + 1, #old_lines - bot do trimmed_old[#trimmed_old + 1] = old_lines[i] end
	for i = top + 1, #new_lines - bot do trimmed_new[#trimmed_new + 1] = new_lines[i] end

	local h = {
		bufnr = bufnr, path = resolved, old_lines = trimmed_old, new_lines = trimmed_new,
		old_text = old_text, row = start_row + top, extmark_ids = {}, accepted = nil,
	}
	hunks[#hunks + 1] = h
	render(h)
	jump(#hunks)

	local n = 0
	for _, hk in ipairs(hunks) do if hk.accepted == nil then n = n + 1 end end
	vim.notify(string.format("lg: %d hunk(s) — ]h/[h navigate, <leader>aha accept, <leader>ahr reject", n), vim.log.levels.INFO)
	-- Clear watcher marks on this buffer so they don't overlap
	pcall(api.nvim_buf_clear_namespace, bufnr, api.nvim_create_namespace("lg_auto_paint"), 0, -1)
	return true
end

function M.next_hunk()
	local pi = pending_indices()
	if #pi == 0 then return vim.notify("lg: no pending hunks", vim.log.levels.INFO) end
	local buf, row = api.nvim_get_current_buf(), api.nvim_win_get_cursor(0)[1]
	for _, i in ipairs(pi) do
		if hunks[i].bufnr == buf and hunks[i].row + 1 > row then return jump(i) end
	end
	jump(pi[1])
end

function M.prev_hunk()
	local pi = pending_indices()
	if #pi == 0 then return vim.notify("lg: no pending hunks", vim.log.levels.INFO) end
	local buf, row = api.nvim_get_current_buf(), api.nvim_win_get_cursor(0)[1]
	for j = #pi, 1, -1 do
		if hunks[pi[j]].bufnr == buf and hunks[pi[j]].row + 1 < row then return jump(pi[j]) end
	end
	jump(pi[#pi])
end

function M.accept()
	local idx = nearest()
	if not idx then return end
	hunks[idx].accepted = true
	clear_extmarks(hunks[idx])
	api.nvim_buf_clear_namespace(hunks[idx].bufnr, dns, 0, -1)
	resolve(hunks[idx], true)
	local changes_ns = api.nvim_create_namespace("lg_auto_paint")
	pcall(api.nvim_buf_clear_namespace, hunks[idx].bufnr, changes_ns, 0, -1)
end

function M.reject()
	local idx = nearest()
	if not idx then return end
	vim.ui.input({ prompt = "Rejection reason: " }, function(reason)
		hunks[idx].accepted = false
		clear_extmarks(hunks[idx])
		api.nvim_buf_clear_namespace(hunks[idx].bufnr, dns, 0, -1)
		resolve(hunks[idx], false, reason)
		local changes_ns = api.nvim_create_namespace("lg_auto_paint")
		pcall(api.nvim_buf_clear_namespace, hunks[idx].bufnr, changes_ns, 0, -1)
	end)
end

function M.accept_all()
	for _, h in ipairs(hunks) do
		if h.accepted == nil then
			h.accepted = true
			clear_extmarks(h)
			resolve(h, true)
		end
	end
end

function M.reject_all()
	vim.ui.input({ prompt = "Rejection reason (all hunks): " }, function(reason)
		for _, h in ipairs(hunks) do
			if h.accepted == nil then
				h.accepted = false
				clear_extmarks(h)
				resolve(h, false, reason)
			end
		end
	end)
end

function M.clear()
	for _, h in ipairs(hunks) do
		clear_extmarks(h)
		if h.on_resolve then
			h.on_resolve(false)
			h.on_resolve = nil
		end
	end
	hunks = {}
end

return M
