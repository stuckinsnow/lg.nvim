--- ACP client: thin Lua layer over the lg-acp Go binary.
---
--- Connects to lg-acp via unix socket. Sends JSON requests, receives
--- streamed NDJSON events. Replaces the old process.lua + handlers.lua.

local M = {}

local sock_path = "/dev/shm/lg-acp.sock"
local conn = nil --- @type uv.uv_pipe_t?
local connected = false
local read_buf = ""
local event_handlers = {} --- @type table<string, fun(ev: table)[]>
local response_queue = {} --- @type fun(resp: table)[] FIFO queue

-- ── Connection ─────────────────────────────────────────────────────

--- Connect to the lg-acp socket. Async — calls on_connect when done.
--- @param on_connect fun(ok: boolean)
function M.connect(on_connect)
	if connected then
		on_connect(true)
		return
	end
	if conn then
		pcall(function() conn:close() end)
		conn = nil
	end
	local pipe = vim.uv.new_pipe(false)
	if not pipe then
		on_connect(false)
		return
	end
	pipe:connect(sock_path, function(err)
		if err then
			pipe:close()
			vim.schedule(function() on_connect(false) end)
			return
		end
		conn = pipe
		connected = true
		pipe:read_start(function(read_err, data)
			if read_err or not data then
				vim.schedule(function() M.disconnect() end)
				return
			end
			vim.schedule(function() M._on_data(data) end)
		end)
		-- Verify connection is alive with a ping
		vim.schedule(function()
			local got_response = false
			M.send({ method = "status" }, function(resp)
				got_response = true
				if resp and resp.ok then
					on_connect(true)
				else
					M.disconnect()
					on_connect(false)
				end
			end)
			-- Timeout: if no response in 1s, socket is dead
			local t = vim.uv.new_timer()
			if not t then return end
			t:start(1000, 0, function()
				t:close()
				if not got_response then
					vim.schedule(function()
						response_queue = {}
						M.disconnect()
						on_connect(false)
					end)
				end
			end)
		end)
	end)
end

function M.disconnect()
	if conn then
		pcall(function()
			conn:read_stop()
			conn:close()
		end)
		conn = nil
	end
	connected = false
	read_buf = ""
end

--- @return boolean
function M.is_connected()
	return connected
end

-- ── Send / receive ─────────────────────────────────────────────────

--- @param request table
--- @param callback? fun(resp: table)
function M.send(request, callback)
	if not connected then
		if callback then callback({ error = "not connected" }) end
		return
	end
	if callback then
		table.insert(response_queue, callback)
	end
	local data = vim.json.encode(request) .. "\n"
	if conn then pcall(function() conn:write(data) end) end
end

--- @param data string
function M._on_data(data)
	read_buf = read_buf .. data
	while true do
		local nl = read_buf:find("\n")
		if not nl then break end
		local line = read_buf:sub(1, nl - 1)
		read_buf = read_buf:sub(nl + 1)
		if line ~= "" then
			local ok, msg = pcall(vim.json.decode, line)
			if ok then M._dispatch(msg) end
		end
	end
end

--- @param msg table
function M._dispatch(msg)
	-- Synchronous response (has "ok" or "error" at top level, no "type")
	if msg.ok ~= nil or (msg.error and not msg.type) then
		local cb = table.remove(response_queue, 1)
		if cb then cb(msg) end
		return
	end
	-- Streamed event
	local t = msg.type
	if t and event_handlers[t] then
		for _, handler in ipairs(event_handlers[t]) do handler(msg) end
	end
	if event_handlers["*"] then
		for _, handler in ipairs(event_handlers["*"]) do handler(msg) end
	end
end

-- ── Event handlers ─────────────────────────────────────────────────

--- @param event_type string
--- @param handler fun(ev: table)
--- @return fun() unsubscribe
function M.on(event_type, handler)
	if not event_handlers[event_type] then
		event_handlers[event_type] = {}
	end
	table.insert(event_handlers[event_type], handler)
	return function()
		local list = event_handlers[event_type]
		if list then
			for i, h in ipairs(list) do
				if h == handler then
					table.remove(list, i)
					return
				end
			end
		end
	end
end

function M.clear_handlers()
	event_handlers = {}
end

-- ── High-level API ─────────────────────────────────────────────────

function M.create_session(cwd, mcp_servers, callback)
	local req = { method = "create_session", cwd = cwd }
	if mcp_servers and next(mcp_servers) then
		req.mcp_servers = mcp_servers
	end
	M.send(req, callback)
end

function M.prompt(session_id, prompt, callback)
	M.send({ method = "prompt", session_id = session_id, prompt = prompt }, callback)
end

function M.set_mode(session_id, mode_id, callback)
	M.send({ method = "set_mode", session_id = session_id, mode_id = mode_id }, callback)
end

function M.set_model(session_id, model_id, callback)
	M.send({ method = "set_model", session_id = session_id, model_id = model_id }, callback)
end

function M.cancel(session_id)
	M.send({ method = "cancel", session_id = session_id }, function() end)
end

function M.destroy_session(session_id)
	M.send({ method = "destroy_session", session_id = session_id }, function() end)
end

function M.respond_permission(session_id, rpc_id, option_id)
	M.send({ method = "respond_permission", session_id = session_id, rpc_id = rpc_id, option_id = option_id }, function() end)
end

function M.get_models(callback)
	M.send({ method = "get_models" }, callback)
end

function M.list_sessions(cwd, callback)
	M.send({ method = "list_sessions", cwd = cwd }, callback)
end

function M.delete_session(session_id, callback)
	M.send({ method = "delete_session", session_id = session_id }, callback)
end

function M.load_session(session_id, cwd, callback)
	M.send({ method = "load_session", session_id = session_id, cwd = cwd }, callback)
end

function M.terminate()
	M.send({ method = "terminate" }, function() end)
end

function M.execute_command(session_id, command, callback)
	M.send({ method = "execute_command", session_id = session_id, command = command }, callback)
end

return M
