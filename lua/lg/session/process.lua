--- ACP process lifecycle + NDJSON transport
---
--- Manages a single kiro-cli/opencode ACP subprocess.
--- Handles: spawn, initialize handshake, NDJSON framing, session creation.
--- Multiple sessions can be multiplexed on one process via create_session().

--- @class lg.Process
--- @field proc vim.SystemObj?
--- @field next_id number
--- @field stdout_buf string
--- @field models table?
--- @field sessions table<string, lg.ProcessSession>
--- @field _ready boolean
--- @field _pending_sessions table<number, any>
--- @field _handshake? fun(msg: table)
local Process = {}
Process.__index = Process

--- @class lg.ProcessSession
--- @field session_id string?
--- @field models table?
--- @field on_message fun(session: lg.ProcessSession, msg: table)
--- @field process lg.Process
--- @field killed? boolean
--- @field _on_done? table<number, fun()>
--- @field _seen_tool_calls? table<string, boolean|string>
--- @field _prompt_count? number
--- @field write fun(self: lg.ProcessSession, msg: table)
--- @field next_rpc_id fun(self: lg.ProcessSession): number
--- @field track_response fun(self: lg.ProcessSession, rpc_id: number)

--- Write JSON-RPC to the process stdin
--- @param msg table
function Process:write(msg)
	if self.proc then
		self.proc:write(vim.json.encode(msg) .. "\n")
	end
end

--- Allocate the next JSON-RPC id
--- @return number
function Process:next_rpc_id()
	local id = self.next_id
	self.next_id = id + 1
	return id
end

--- Route an incoming message to the correct session
--- @param msg table
function Process:_route(msg)
	-- Notifications and requests carry sessionId in params
	local sid = msg.params and msg.params.sessionId
	if sid and self.sessions[sid] then
		self.sessions[sid].on_message(self.sessions[sid], msg)
		return
	end
	-- Responses (id + result/error) — check pending map
	if msg.id and self._pending_sessions[msg.id] then
		local session = self._pending_sessions[msg.id]
		self._pending_sessions[msg.id] = nil
		session.on_message(session, msg)
		return
	end
	-- Fallback: route to first session (handles untracked responses like set_mode acks)
	for _, session in pairs(self.sessions) do
		session.on_message(session, msg)
		return
	end
end

--- Track an RPC id so the response routes to the right session
--- @param rpc_id number
--- @param session lg.ProcessSession
function Process:track_response(rpc_id, session)
	self._pending_sessions[rpc_id] = session
end

--- Create a new ACP session on this process
--- @param on_message fun(session: lg.ProcessSession, msg: table)
--- @param mcp_servers? table
--- @param on_ready fun(session: lg.ProcessSession?)
function Process:create_session(on_message, mcp_servers, on_ready)
	local id = self:next_rpc_id()
	--- @type lg.ProcessSession
	local session = setmetatable({
		session_id = nil,
		on_message = on_message,
		process = self,
	}, { __index = Process._session_methods })

	-- Intercept the session/new response
	self._pending_sessions[id] = {
		on_message = function(_, msg)
			if msg.error or not msg.result or not msg.result.sessionId then
				on_ready(nil)
				return
			end
			session.session_id = msg.result.sessionId
			session.models = msg.result.models
			if session.models and not session.models.currentModelId then
				local avail = session.models.availableModels
				if avail and avail[1] then
					session.models.currentModelId = avail[1].modelId
				end
			end
			self.sessions[session.session_id] = session
			if not self.models and session.models then
				self.models = session.models
			end
			on_ready(session)
		end,
	}

	self:write({
		jsonrpc = "2.0",
		id = id,
		method = "session/new",
		params = { cwd = vim.fn.getcwd(), mcpServers = mcp_servers or {} },
	})
end

--- Remove a session from the process
--- @param session_id string
function Process:remove_session(session_id)
	self.sessions[session_id] = nil
end

--- @return boolean
function Process:is_healthy()
	return self._ready and self.proc ~= nil
end

--- Kill the process
function Process:terminate()
	if self.proc then
		pcall(function()
			self.proc:kill(9)
		end)
	end
	self.proc = nil
	self._ready = false
	self.sessions = {}
end

-- Session convenience methods (delegated to process)
Process._session_methods = {}

--- @param msg table
function Process._session_methods:write(msg)
	self.process:write(msg)
end

--- @return number
function Process._session_methods:next_rpc_id()
	return self.process:next_rpc_id()
end

--- @param rpc_id number
function Process._session_methods:track_response(rpc_id)
	self.process:track_response(rpc_id, self)
end

--- Spawn an ACP process, run initialize handshake, call on_ready(process).
--- @param spawn_opts { cmd: string[], client_name?: string }
--- @param on_ready fun(process: lg.Process?)
--- @return lg.Process?
function Process.spawn(spawn_opts, on_ready)
	local self = setmetatable({
		proc = nil,
		next_id = 1,
		stdout_buf = "",
		models = nil,
		sessions = {},
		_ready = false,
		_pending_sessions = {},
		_handshake = nil,
	}, Process)

	local function process_stdout(data)
		self.stdout_buf = self.stdout_buf .. data
		while true do
			local nl = self.stdout_buf:find("\n")
			if not nl then
				break
			end
			local line = self.stdout_buf:sub(1, nl - 1):gsub("\r$", "")
			self.stdout_buf = self.stdout_buf:sub(nl + 1)
			if line ~= "" and line:match("^%s*{") then
				local ok, msg = pcall(vim.json.decode, line)
				if ok then
					if self._handshake then
						self._handshake(msg)
					else
						self:_route(msg)
					end
				end
			end
		end
	end

	local proc = vim.system(
		spawn_opts.cmd,
		{
			stdin = true,
			cwd = vim.fn.getcwd(),
			stdout = vim.schedule_wrap(function(_, data)
				if data then
					process_stdout(data)
				end
			end),
			stderr = vim.schedule_wrap(function() end),
		},
		vim.schedule_wrap(function()
			self.proc = nil
			self._ready = false
		end)
	)
	self.proc = proc

	-- Initialize handshake
	self._handshake = function(msg)
		self._handshake = nil
		if msg.error or not msg.result then
			on_ready(nil)
			return
		end
		self._ready = true
		on_ready(self)
	end

	local id = self:next_rpc_id()
	self:write({
		jsonrpc = "2.0",
		id = id,
		method = "initialize",
		params = {
			protocolVersion = 1,
			clientCapabilities = { fs = { readTextFile = true, writeTextFile = false } },
			clientInfo = { name = spawn_opts.client_name or "lg", version = "2.0.0" },
		},
	})

	return self
end

return Process
