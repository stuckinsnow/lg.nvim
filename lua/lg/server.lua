--- Unix socket server for receiving paint edits from MCP server
--- All in-memory, no disk writes

local diff = require("lg.diff")
local paint = require("lg.paint")

local M = {}

local server = nil
---@type string?
local sock_path = nil

--- Encode regions as JSON for MCP server to read
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
		local regions = paint.get_all()
		local edits = msg.edits or {}
		diff.apply_all(regions, edits)
		paint.clear()
		vim.cmd("redraw")
		return vim.json.encode({ ok = true, count = #edits })
	elseif msg.method == "paint_regions" then
		local ns_auto = vim.api.nvim_create_namespace("lg_auto_paint")
		local regions = msg.regions or {}
		local count = 0
		local first_file, first_line
		for _, r in ipairs(regions) do
			local path = r.file
			local s_line = r.start_line
			local e_line = r.end_line
			if path and s_line and e_line then
				local bufnr = vim.fn.bufnr(path)
				if bufnr == -1 then
					vim.cmd("edit " .. vim.fn.fnameescape(path))
					bufnr = vim.fn.bufnr(path)
				elseif not vim.api.nvim_buf_is_loaded(bufnr) then
					vim.fn.bufload(bufnr)
				end
				if bufnr ~= -1 then
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
					if not first_file then
						first_file = path
						first_line = s_line
					end
				end
			end
		end
		if first_file then
			vim.cmd("edit " .. vim.fn.fnameescape(first_file))
			vim.api.nvim_win_set_cursor(0, { first_line, 0 })
			vim.cmd("normal! zz")
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
		client:read_start(function(read_err, data)
			if read_err or not data then
				if client then
					client:close()
				end
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
					local response = M.handle_message(line)
					if client then
						client:write(response .. "\n")
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

return M
