--- Unix socket server for receiving paint edits from MCP server
--- All in-memory, no disk writes

local diff = require("lg.ui.diff")
local paint = require("lg.ui.paint")

local M = {}

local server = nil
---@type string?

--- Apply edits to regions sorted bottom-up, shifting paint after each.
--- @param regs table[] region list (must have bufnr, start_line, end_line)
--- @param edits table[] edits with region_id and new_code
local function apply_sorted_edits(regs, edits)
	local sorted = {}
	for _, e in ipairs(edits) do
		local idx = (e.region_id or -1) + 1
		local r = regs[idx]
		if r and vim.api.nvim_buf_is_valid(r.bufnr) then
			table.insert(sorted, { region = r, new_lines = vim.split(e.new_code:gsub("\n$", ""), "\n") })
		end
	end
	table.sort(sorted, function(a, b)
		return a.region.start_line > b.region.start_line
	end)
	for _, entry in ipairs(sorted) do
		local r = entry.region
		diff.apply(r.bufnr, r.start_line - 1, r.end_line, entry.new_lines)
		local delta = #entry.new_lines - (r.end_line - r.start_line + 1)
		paint.shift_after(r.bufnr, r.start_line, delta)
		paint.remove(r)
		-- Remove from the passed-in regs table too
		for i, reg in ipairs(regs) do
			if reg == r then
				table.remove(regs, i)
				break
			end
		end
	end
	return #sorted
end

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

--- Read buffer content (or fall back to disk)
--- @param path string absolute path
--- @param start_line? number 1-based
--- @param end_line? number 1-based inclusive
--- @return string JSON response
function M.do_read_buffer(path, start_line, end_line)
	local bufnr = vim.fn.bufnr(path)
	local lines
	if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
		local total = vim.api.nvim_buf_line_count(bufnr)
		start_line = start_line and math.max(1, start_line) or 1
		end_line = end_line and math.min(end_line, total) or total
		lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
		return vim.json.encode({ content = table.concat(lines, "\n"), start_line = start_line, end_line = end_line, total_lines = total })
	else
		local f = io.open(path, "r")
		if not f then
			return vim.json.encode({ error = "file not found: " .. path })
		end
		local content = f:read("*a")
		f:close()
		local all_lines = vim.split(content:gsub("\n$", ""), "\n")
		local total = #all_lines
		start_line = start_line and math.max(1, start_line) or 1
		end_line = end_line and math.min(end_line, total) or total
		lines = {}
		for i = start_line, end_line do lines[#lines + 1] = all_lines[i] end
		return vim.json.encode({ content = table.concat(lines, "\n"), start_line = start_line, end_line = end_line, total_lines = total })
	end
end

--- Handle a complete message from MCP server
--- @param data string JSON: { "method": "get_regions" } or { "method": "apply_edit", "region_id": 0, "new_code": "..." }
--- @return string|nil response, (fun():string?)|nil poll_fn
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
		local new_lines = vim.split(msg.new_code:gsub("\n$", ""), "\n")
		diff.apply(region.bufnr, region.start_line - 1, region.end_line, new_lines)
		paint.shift_after(region.bufnr, region.start_line, #new_lines - (region.end_line - region.start_line + 1))
		paint.remove(region)
		vim.cmd("redraw")
		return vim.json.encode({ ok = true })
	elseif msg.method == "apply_edits" then
		local edits = msg.edits or {}
		if msg.session and sessions[msg.session] then
			-- Session-scoped: edit that session's regions
			local count = apply_sorted_edits(sessions[msg.session], edits)
			if count == 0 then
				return vim.json.encode({ error = "no painted regions to edit" })
			end
		elseif msg.edit_token and msg.edit_token ~= "" then
			-- Token-scoped: edit only the snapshot regions
			local regs = tokens[msg.edit_token]
			if not regs then
				return vim.json.encode({ error = "invalid edit_token" })
			end
			apply_sorted_edits(regs, edits)
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
		if not path or path == "" or not old_text or not new_text then
			return vim.json.encode({ error = "path, old_text, new_text required" })
		end
		local hunk = require("lg.ui.hunk")
		local result = nil
		hunk.propose_write(path, old_text, new_text, function(accepted, reason)
			if accepted then
				-- Apply the edit to the buffer (not disk — user saves when ready)
				local resolved = vim.fn.fnamemodify(path, ":p")
				local bufnr = vim.fn.bufnr(resolved)
				if bufnr == -1 then
					-- File not open — try opening it
					vim.cmd("edit " .. vim.fn.fnameescape(resolved))
					bufnr = vim.fn.bufnr(resolved)
				end
				if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
					local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
					local content = table.concat(lines, "\n")
					local s, e = content:find(old_text, 1, true)
					if s then
						local updated = content:sub(1, s - 1) .. new_text .. content:sub(e + 1)
						local new_lines = vim.split(updated:gsub("\n$", ""), "\n")
						vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
						vim.bo[bufnr].modified = true
					end
				else
					-- Fallback for new files: write to disk
					vim.fn.mkdir(vim.fn.fnamemodify(resolved, ":h"), "p")
					local fw = io.open(resolved, "w")
					if fw then
						fw:write(new_text)
						fw:close()
					end
					vim.cmd("edit " .. vim.fn.fnameescape(resolved))
				end
				result = vim.json.encode({ ok = true, status = "accepted" })
			else
				local err_msg = "User rejected edit"
				if reason and reason ~= "" then
					err_msg = err_msg .. ": " .. reason
				end
				result = vim.json.encode({ ok = false, status = "rejected", error = err_msg })
			end
		end)
		return nil, function() return result end
	elseif msg.method == "read_buffer" then
		local path = msg.path
		if not path or path == "" then
			return vim.json.encode({ error = "path required" })
		end
		path = vim.fn.expand(path)
		path = vim.fn.fnamemodify(path, ":p")
		-- Block env/secret files
		local basename = vim.fn.fnamemodify(path, ":t")
		if basename:match("^%.env") or basename:match("%.pem$") or basename:match("%.key$") then
			return vim.json.encode({ error = "access denied: " .. basename })
		end
		-- Check if outside project root
		local root = vim.fn.getcwd() .. "/"
		if not path:find(root, 1, true) then
			local result = nil
			vim.ui.select({ "Allow", "Deny" }, { prompt = "Read outside project: " .. path }, function(_, idx)
				if idx == 1 then
					result = M.do_read_buffer(path, msg.start_line, msg.end_line)
				else
					result = vim.json.encode({ error = "access denied by user" })
				end
			end)
			return nil, function() return result end
		end
		return M.do_read_buffer(path, msg.start_line, msg.end_line)
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
						if timer then
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
