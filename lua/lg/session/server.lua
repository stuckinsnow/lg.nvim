--- Unix socket server for receiving paint edits from MCP server
--- All in-memory, no disk writes

local diff = require("lg.ui.diff")
local paint = require("lg.ui.paint")

local M = {}

local server = nil
---@type string?

--- Stored info-paint regions for conversion
local info_regions = {}
local sock_path = nil

-- Session-scoped regions for oneshot edits
local sessions = {}

function M.register_session(regions)
	sessions["oneshot"] = regions
	return "oneshot"
end

function M.unregister_session(id)
	sessions[id] = nil
end

-- Edit tokens: scope edits to specific region snapshots
local tokens = {} -- token -> region snapshot

function M.create_token(regions)
	local token = string.format("%04x", math.random(0, 0xFFFF))
	local snapshot = {}
	for i, r in ipairs(regions) do
		snapshot[i] = { bufnr = r.bufnr, file = r.file, start_line = r.start_line, end_line = r.end_line, lines = r.lines }
	end
	tokens[token] = snapshot
	return token
end

function M.clear_tokens()
	tokens = {}
end
--- @return string
function M.encode_regions()
	local regions = paint.get_all()
	local out = {}
	for i, r in ipairs(regions) do
		out[i] = {
			region_id = i - 1,
			file = r.file,
			start_line = r.start_line,
			end_line = r.end_line,
			lines = r.lines,
		}
	end
	return vim.json.encode(out)
end

--- Encode diagnostics as JSON for MCP server
--- @param bufnr? number specific buffer, or nil for all
--- @param min_severity? number minimum severity (1=Error, 2=Warn, 3=Info, 4=Hint)
--- @return string
function M.encode_diagnostics(bufnr, min_severity)
	min_severity = min_severity or 2 -- default: warnings and above
	local bufs = bufnr and { bufnr } or vim.api.nvim_list_bufs()
	local severity_names = { "Error", "Warning", "Info", "Hint" }
	local out = {}
	for _, b in ipairs(bufs) do
		if vim.api.nvim_buf_is_loaded(b) then
			local name = vim.api.nvim_buf_get_name(b)
			if name ~= "" then
				local diags = vim.diagnostic.get(b, { severity = { min = min_severity } })
				for _, d in ipairs(diags) do
					out[#out + 1] = {
						file = name,
						line = d.lnum + 1,
						col = d.col + 1,
						severity = severity_names[d.severity] or "Unknown",
						message = d.message,
						source = d.source or "",
					}
				end
			end
		end
	end
	return vim.json.encode(out)
end

--- Handle a complete message from MCP server
--- @param data string JSON: { "method": "get_regions" } or { "method": "apply_edit", "region_id": 0, "new_code": "..." }
--- @return string JSON response
function M.handle_message(data)
	local ok, msg = pcall(vim.json.decode, data)
	if not ok then
		return vim.json.encode({ error = "invalid json" })
	end

	if msg.method == "get_regions" then
		if msg.session and sessions[msg.session] then
			-- Session-scoped: return only that session's regions
			local regs = sessions[msg.session]
			local out = {}
			for i, r in ipairs(regs) do
				out[i] = {
					region_id = i - 1,
					file = r.file,
					start_line = r.start_line,
					end_line = r.end_line,
					lines = r.lines,
				}
			end
			return vim.json.encode(out)
		end
		if msg.edit_token and msg.edit_token ~= "" then
			local regs = tokens[msg.edit_token]
			if not regs then return vim.json.encode({}) end
			local out = {}
			for i, r in ipairs(regs) do
				out[i] = {
					region_id = i - 1,
					file = r.file,
					start_line = r.start_line,
					end_line = r.end_line,
					lines = r.lines,
				}
			end
			return vim.json.encode(out)
		end
		return M.encode_regions()
	elseif msg.method == "get_diagnostics" then
		return M.encode_diagnostics(msg.bufnr, msg.severity)
	elseif msg.method == "apply_edit" then
		local regions = paint.get_all()
		local idx = (msg.region_id or -1) + 1
		if idx < 1 or idx > #regions then
			return vim.json.encode({ error = "invalid region_id" })
		end
		local region = regions[idx]
		if not vim.api.nvim_buf_is_valid(region.bufnr) then
			return vim.json.encode({ error = "buffer invalid" })
		end
		local new_lines = vim.split(msg.new_code, "\n")
		diff.apply(region.bufnr, region.start_line - 1, region.end_line, new_lines)
		paint.shift_after(region.bufnr, region.start_line, #new_lines - (region.end_line - region.start_line + 1))
		vim.cmd("redraw")
		return vim.json.encode({ ok = true })
	elseif msg.method == "apply_edits" then
		local edits = msg.edits or {}
		if msg.session and sessions[msg.session] then
			-- Session-scoped: edit that session's regions
			local regs = sessions[msg.session]
			for _, e in ipairs(edits) do
				local idx = (e.region_id or -1) + 1
				local r = regs[idx]
				if r and vim.api.nvim_buf_is_valid(r.bufnr) then
					local new_lines = vim.split(e.new_code, "\n")
					diff.apply(r.bufnr, r.start_line - 1, r.end_line, new_lines)
				end
			end
		elseif msg.edit_token and msg.edit_token ~= "" then
			-- Token-scoped: edit only the snapshot regions
			local regs = tokens[msg.edit_token]
			if not regs then
				return vim.json.encode({ error = "invalid edit_token" })
			end
			for _, e in ipairs(edits) do
				local idx = (e.region_id or -1) + 1
				local r = regs[idx]
				if r and vim.api.nvim_buf_is_valid(r.bufnr) then
					local new_lines = vim.split(e.new_code, "\n")
					diff.apply(r.bufnr, r.start_line - 1, r.end_line, new_lines)
				end
			end
		else
			-- Global paint (only if no tokens exist)
			if next(tokens) then
				return vim.json.encode({ error = "edit_token required" })
			end
			local regions = paint.get_all()
			diff.apply_all(regions, edits)
		end
		vim.cmd("redraw")
		return vim.json.encode({ ok = true, count = #edits })
	elseif msg.method == "edit_file" then
		local path = msg.path
		local old_text = msg.old_text
		local new_text = msg.new_text
		if not path or not old_text or not new_text then
			return vim.json.encode({ error = "path, old_text, new_text required" })
		end
		local hunk = require("lg.ui.hunk")
		local result = nil
		hunk.propose_write(path, old_text, new_text, function(accepted, reason)
			if accepted then
				-- Apply the edit to disk
				local resolved = vim.fn.fnamemodify(path, ":p")
				local f = io.open(resolved, "r")
				if f then
					local content = f:read("*a")
					f:close()
					local s, e = content:find(old_text, 1, true)
					if s then
						local updated = content:sub(1, s - 1) .. new_text .. content:sub(e + 1)
						local fw = io.open(resolved, "w")
						if fw then
							fw:write(updated)
							fw:close()
						end
					end
				end
				for _, buf in ipairs(vim.api.nvim_list_bufs()) do
					if vim.api.nvim_buf_is_loaded(buf) then
						local bname = vim.api.nvim_buf_get_name(buf)
						if bname == resolved or bname == path then
							vim.bo[buf].autoread = true
							vim.cmd("checktime " .. buf)
						end
					end
				end
				result = vim.json.encode({ ok = true, status = "accepted" })
			else
				local msg = "User rejected edit"
				if reason and reason ~= "" then
					msg = msg .. ": " .. reason
				end
				result = vim.json.encode({ ok = false, status = "rejected", error = msg })
			end
		end)
		return nil, function() return result end
	elseif msg.method == "paint_regions" then
		local ns_auto = vim.api.nvim_create_namespace("lg_auto_paint")
		local regions = msg.regions or {}
		local count = 0
		local first_file, first_line
		info_regions = {}
		local qf_items = {}
		for _, r in ipairs(regions) do
			local path = r.file
			local s_line = r.start_line
			local e_line = r.end_line
			local desc = r.description or ""
			if path and s_line and e_line then
				-- Strip kiro-cli tmp prefix and resolve to project root
				path = path:gsub("^/tmp/tmp%.[^/]+/", "")
				path = vim.fn.fnamemodify(path, ":p")
				local bufnr = vim.fn.bufnr(path)
				if bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr) then
					-- find a normal window to open in
					local target
					for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
						local b = vim.api.nvim_win_get_buf(win)
						if vim.bo[b].buftype == "" then target = win; break end
					end
					if target then
						vim.api.nvim_win_call(target, function()
							vim.cmd("edit " .. vim.fn.fnameescape(path))
						end)
					end
					bufnr = vim.fn.bufnr(path)
				end
				if bufnr ~= -1 then
					local total_lines = vim.api.nvim_buf_line_count(bufnr)
					e_line = math.min(e_line, total_lines)
					for row = s_line - 1, e_line - 1 do
						local total = e_line - s_line + 1
						local sign = "│"
						if total == 1 then sign = "│"
						elseif row == s_line - 1 then sign = "┌"
						elseif row == e_line - 1 then sign = "└" end
						vim.api.nvim_buf_set_extmark(bufnr, ns_auto, row, 0, {
							end_line = row + 1, hl_group = "LgAutoPaintLine", hl_eol = true, priority = 110,
						})
						vim.api.nvim_buf_set_extmark(bufnr, ns_auto, row, 0, {
							sign_text = sign, sign_hl_group = "LgAutoPaintSign", priority = 110,
						})
					end
					count = count + 1
					table.insert(info_regions, { bufnr = bufnr, start_line = s_line, end_line = e_line })
					local text = desc ~= "" and ("AI - " .. desc) or "AI"
					table.insert(qf_items, { filename = path, lnum = s_line, text = text, bufnr = 0 })
					if not first_file then
						first_file = path
						first_line = s_line
					end
				end
			end
		end
		if #qf_items > 0 then
			vim.fn.setqflist(qf_items, "a")
		end
		-- Navigate to first painted region in a non-chat window
		if first_file then
			local target_win
			for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
				local b = vim.api.nvim_win_get_buf(win)
				if vim.bo[b].buftype == "" then
					target_win = win
					break
				end
			end
			if target_win then
				local bufnr = vim.fn.bufnr(first_file)
				if bufnr ~= -1 then
					vim.api.nvim_win_set_buf(target_win, bufnr)
					pcall(vim.api.nvim_win_set_cursor, target_win, { first_line, 0 })
					vim.api.nvim_win_call(target_win, function() vim.cmd("normal! zz") end)
				end
			end
		end
		vim.cmd("redraw")
		return vim.json.encode({ ok = true, count = count })
	end

	return vim.json.encode({ error = "unknown method" })
end

--- @return string?
function M.start()
	if server then
		return sock_path
	end

	sock_path = "/dev/shm/lg.sock"
	vim.fn.delete(sock_path)

	server = vim.uv.new_pipe(false)
	if not server then
		return nil
	end
	server:bind(sock_path)
	server:listen(8, function(err)
		if err or not server then
			return
		end
		local client = vim.uv.new_pipe(false)
		if not client then
			return
		end
		server:accept(client)

		local buf = ""
		local active_timer = nil
		client:read_start(function(read_err, data)
			if read_err or not data then
				if active_timer then
					pcall(function() active_timer:stop(); active_timer:close() end)
					active_timer = nil
				end
				pcall(function() if client then client:close() end end)
				return
			end
			buf = buf .. data
			while true do
				local nl = buf:find("\n")
				if not nl then
					break
				end
				local line = buf:sub(1, nl - 1)
				buf = buf:sub(nl + 1)
				vim.schedule(function()
					local response, poll_fn = M.handle_message(line)
					if response then
						pcall(function() if client then client:write(response .. "\n") end end)
					elseif poll_fn then
						-- Async: poll until result is ready
						local timer = vim.uv.new_timer()
						active_timer = timer
						timer:start(50, 50, vim.schedule_wrap(function()
							local result = poll_fn()
							if result then
								if not timer:is_closing() then
									timer:stop()
									timer:close()
								end
								active_timer = nil
								pcall(function() if client then client:write(result .. "\n") end end)
							end
						end))
					end
				end)
			end
		end)
	end)

	return sock_path
end

function M.stop()
	if server then
		---@diagnostic disable-next-line: undefined-field
		server:close()
		server = nil
	end
	if sock_path then
		vim.fn.delete(sock_path)
		sock_path = nil
	end
end

--- @return string?
function M.get_sock_path()
	return sock_path
end

function M.convert_info_paint()
	local ns_auto = vim.api.nvim_create_namespace("lg_auto_paint")
	for _, r in ipairs(info_regions) do
		if vim.api.nvim_buf_is_valid(r.bufnr) then
			paint.add(r.bufnr, r.start_line, r.end_line)
		end
	end
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_clear_namespace(buf, ns_auto, 0, -1)
		end
	end
	local count = #info_regions
	info_regions = {}
	return count
end

function M.clear_info_paint()
	local ns_auto = vim.api.nvim_create_namespace("lg_auto_paint")
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_clear_namespace(buf, ns_auto, 0, -1)
		end
	end
	info_regions = {}
end

function M.get_info_regions()
	return info_regions
end

function M.add_info_region(bufnr, s_line, e_line)
	local ns_auto = vim.api.nvim_create_namespace("lg_auto_paint")
	local total_lines = vim.api.nvim_buf_line_count(bufnr)
	e_line = math.min(e_line, total_lines)
	for row = s_line - 1, e_line - 1 do
		local total = e_line - s_line + 1
		local sign = "│"
		if total == 1 then sign = "│"
		elseif row == s_line - 1 then sign = "┌"
		elseif row == e_line - 1 then sign = "└" end
		vim.api.nvim_buf_set_extmark(bufnr, ns_auto, row, 0, {
			end_line = row + 1, hl_group = "LgAutoPaintLine", hl_eol = true, priority = 110,
		})
		vim.api.nvim_buf_set_extmark(bufnr, ns_auto, row, 0, {
			sign_text = sign, sign_hl_group = "LgAutoPaintSign", priority = 110,
		})
	end
	table.insert(info_regions, { bufnr = bufnr, start_line = s_line, end_line = e_line })
end

return M
