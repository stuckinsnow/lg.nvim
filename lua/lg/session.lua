--- Session: manages a persistent kiro-cli ACP subprocess
--- Handles: spawn, initialize, session/new, session/prompt lifecycle.

local protocol = require("lg.protocol")
local status = require("lg.status")

local M = {}

local state = nil
local opts = {}

local providers = {
	kiro = { cmd = { "kiro-cli", "acp" }, name = "Kiro" },
	opencode = { cmd = { "opencode", "acp" }, name = "OpenCode" },
}

local state_path = "/dev/shm/lg-state.json"

local function load_state()
	local f = io.open(state_path, "r")
	if not f then return {} end
	local ok, data = pcall(vim.json.decode, f:read("*a"))
	f:close()
	return ok and data or {}
end

local function save_state(t)
	local f = io.open(state_path, "w")
	if f then f:write(vim.json.encode(t)); f:close() end
end

function M.setup(user_opts)
	opts = vim.tbl_deep_extend("force", {
		cmd = { "kiro-cli", "acp" },
		timeout = 30000,
		mcp_servers = {},
		provider = "kiro",
	}, user_opts or {})

	-- Restore persisted provider
	local saved = load_state()
	if saved.provider and providers[saved.provider] then
		opts.provider = saved.provider
	end

	if providers[opts.provider] then
		opts.cmd = providers[opts.provider].cmd
	end
end

--- @param s table
--- @param msg table
local function write(s, msg)
	if s.proc then
		s.proc:write(vim.json.encode(msg) .. "\n")
	end
end

--- @param s table
--- @param method string
--- @param params table
--- @return table?
local function rpc_request(s, method, params)
	local id = s.next_id
	s.next_id = id + 1
	write(s, { jsonrpc = "2.0", id = id, method = method, params = params or {} })

	local start = vim.uv.hrtime()
	local timeout_ns = opts.timeout * 1e6
	while vim.uv.hrtime() - start < timeout_ns do
		vim.wait(10)
		if s.pending[id] then
			local resp = s.pending[id]
			s.pending[id] = nil
			if resp.error then
				status.stop("Error: " .. method)
				return nil
			end
			return resp.result
		end
	end
	status.stop("Timeout: " .. method)
	return nil
end

--- @param s table
--- @param msg table
local function handle_message(s, msg)
	if msg.id and not msg.method then
		s.pending[msg.id] = { result = msg.result, error = msg.error }
		if msg.result and msg.result.stopReason then
			vim.schedule(function()
				status.stop("Done")
				vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestFinished" })
				if s._on_done then
					s._on_done()
					s._on_done = nil
				end
			end)
		end
		return
	end

	local method = msg.method or ""

	if method == "session/update" then
		local update = msg.params and msg.params.update
		if update then
			if update.sessionUpdate == "agent_message_chunk" then
				local content = update.content
				if content and content.type == "text" and content.text then
					vim.schedule(function()
						require("lg.window").append_agent_text(content.text)
					end)
				end
			elseif update.sessionUpdate == "tool_call" then
				vim.schedule(function()
					local title = update.title or update.toolCallId or "unknown"
					status.update("Tool: " .. title)
					vim.api.nvim_exec_autocmds("User", { pattern = "LgToolCall", data = { title = title } })
				end)
			end
		end
	elseif method == "session/request_permission" then
		local tool_options = msg.params and msg.params.options or {}
		local option_id
		for _, opt in ipairs(tool_options) do
			if opt.kind == "allow_always" or opt.kind == "allow_once" then
				option_id = opt.optionId
				break
			end
		end
		option_id = option_id or (tool_options[1] and tool_options[1].optionId)

		if option_id and msg.id then
			vim.schedule(function()
				local tc = msg.params and msg.params.toolCall
				status.update("Approved: " .. (tc and tc.title or ""))
			end)
			write(s, {
				jsonrpc = "2.0",
				id = msg.id,
				result = { outcome = { outcome = "selected", optionId = option_id } },
			})
		end
	elseif method == "fs/read_text_file" then
		local path = msg.params and msg.params.path
		if path and msg.id then
			vim.schedule(function()
				status.update("Reading: " .. vim.fn.fnamemodify(path, ":t"))
			end)
			local content = ""
			local f = io.open(path, "r")
			if f then
				content = f:read("*a")
				f:close()
			end
			write(s, { jsonrpc = "2.0", id = msg.id, result = { content = content } })
		end
	elseif method == "fs/write_text_file" then
		local path = msg.params and msg.params.path
		local content = msg.params and msg.params.content or ""
		if path and msg.id then
			vim.schedule(function()
				local short = vim.fn.fnamemodify(path, ":~:.")
				local choice = vim.fn.confirm("Write to " .. short .. "?", "&Yes\n&No", 1)
				if choice == 1 then
					local f = io.open(path, "w")
					if f then
						f:write(content)
						f:close()
					end
					write(s, { jsonrpc = "2.0", id = msg.id, result = vim.NIL })
					local lines = vim.split(content, "\n")
					for _, buf in ipairs(vim.api.nvim_list_bufs()) do
						if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == path then
							vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
							vim.bo[buf].modified = false
						end
					end
					vim.cmd("redraw")
				else
					write(s, { jsonrpc = "2.0", id = msg.id, error = { code = -32000, message = "denied" } })
				end
			end)
		end
	elseif method:match("^_kiro") or method:match("^_opencode") then
		-- silently ignore internal notifications
	end
end

--- @param s table
--- @param data string
local function on_stdout(s, data)
	s.stdout_buf = s.stdout_buf .. data
	while true do
		local nl = s.stdout_buf:find("\n")
		if not nl then
			break
		end
		local line = s.stdout_buf:sub(1, nl - 1):gsub("\r$", "")
		s.stdout_buf = s.stdout_buf:sub(nl + 1)
		if line ~= "" and line:match("^%s*{") then
			local ok, msg = pcall(vim.json.decode, line)
			if ok then
				handle_message(s, msg)
			end
		end
	end
end

--- @return table?
local function connect()
	if state and state.proc then
		return state
	end

	status.start("Connecting...")

	local s = {
		proc = nil,
		next_id = 1,
		pending = {},
		session_id = nil,
		stdout_buf = "",
		models = nil,
	}

	local proc = vim.system(
		opts.cmd,
		{
			stdin = true,
			cwd = vim.fn.getcwd(),
			stdout = vim.schedule_wrap(function(_, data)
				if data then
					on_stdout(s, data)
				end
			end),
			stderr = vim.schedule_wrap(function(_, _) end),
		},
		vim.schedule_wrap(function(_)
			s.proc = nil
			s.session_id = nil
		end)
	)

	s.proc = proc
	state = s

	status.update("Initializing...")
	local init = rpc_request(s, "initialize", {
		protocolVersion = 1,
		clientCapabilities = { fs = { readTextFile = true, writeTextFile = true } },
		clientInfo = { name = "lg", version = "2.0.0" },
	})
	if not init then
		M.clear()
		return nil
	end

	status.update("Creating session...")
	local session_result = rpc_request(s, "session/new", {
		cwd = vim.fn.getcwd(),
		mcpServers = opts.mcp_servers,
	})
	if not session_result or not session_result.sessionId then
		status.stop("Failed to create session")
		M.clear()
		return nil
	end
	s.session_id = session_result.sessionId
	s.models = session_result.models

	-- Restore persisted model
	local saved = load_state()
	if saved.model and s.models then
		for _, m in ipairs(s.models.availableModels or {}) do
			if m.modelId == saved.model then
				local id = s.next_id
				s.next_id = id + 1
				write(s, {
					jsonrpc = "2.0",
					id = id,
					method = "session/set_model",
					params = { sessionId = s.session_id, modelId = saved.model },
				})
				s.models.currentModelId = saved.model
				break
			end
		end
	end

	status.stop("Session ready")

	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("lg_session", { clear = true }),
		callback = function()
			M.clear()
		end,
	})

	return s
end

--- @param prompt string
--- @param regions table[]
--- @param context_regions? table[]
--- @param on_done? fun() called when turn completes
--- @param lsp_context? string
--- @param tsc_context? string
function M.send(prompt, regions, context_regions, on_done, lsp_context, tsc_context)
	local s = connect()
	if not s then
		return
	end

	local messages = protocol.build_prompt(regions, context_regions or {}, prompt, lsp_context, tsc_context)

	status.start("Thinking...")
	vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestStarted" })

	-- Store on_done for when turn completes
	s._on_done = on_done

	local id = s.next_id
	s.next_id = id + 1
	write(s, {
		jsonrpc = "2.0",
		id = id,
		method = "session/prompt",
		params = { sessionId = s.session_id, prompt = messages },
	})
end

function M.clear()
	if not state then
		return
	end
	if state.proc then
		pcall(function()
			state.proc:kill(9)
		end)
	end
	state = nil
end

function M.kill()
	if not state then return end
	if state.proc then
		pcall(function() state.proc:kill(9) end)
	end
	state.proc = nil
	state.session_id = nil
end

--- @return boolean
function M.is_active()
	return state ~= nil and state.proc ~= nil
end

function M.select_model()
	local s = connect()
	if not s or not s.models then
		vim.notify("lg: no models available", vim.log.levels.WARN)
		return
	end

	local names = {}
	for _, m in ipairs(s.models.availableModels or {}) do
		local label = m.modelId
		if m.modelId == s.models.currentModelId then
			label = label .. " (current)"
		end
		table.insert(names, label)
	end

	vim.ui.select(
		names,
		{ prompt = "lg model (current: " .. (s.models.currentModelId or "?") .. "):" },
		function(choice)
			if not choice then
				return
			end
			local model_id = choice:gsub(" %(current%)$", "")
			local id = s.next_id
			s.next_id = id + 1
			write(s, {
				jsonrpc = "2.0",
				id = id,
				method = "session/set_model",
				params = { sessionId = s.session_id, modelId = model_id },
			})
			s.models.currentModelId = model_id
			save_state({ provider = opts.provider, model = model_id })
			vim.notify("lg: model → " .. model_id, vim.log.levels.INFO)
		end
	)
end

--- @return string?
function M.current_model()
	if state and state.models then
		return state.models.currentModelId
	end
	local saved = load_state()
	return saved.model
end

function M.current_provider()
	return opts.provider
end

function M.select_provider()
	local names = {}
	for key, p in pairs(providers) do
		local label = p.name
		if opts.provider == key then
			label = label .. " (current)"
		end
		table.insert(names, { key = key, label = label })
	end
	table.sort(names, function(a, b)
		return a.label < b.label
	end)

	local labels = vim.tbl_map(function(n)
		return n.label
	end, names)

	vim.ui.select(
		labels,
		{ prompt = "lg provider (current: " .. (providers[opts.provider].name or "?") .. "):" },
		function(choice, idx)
			if not choice or not idx then
				return
			end
			local picked = names[idx].key
			if picked == opts.provider and state then
				return
			end
			opts.provider = picked
			opts.cmd = providers[picked].cmd
			M.clear()
			save_state({ provider = picked, model = M.current_model() })
			vim.notify("lg: provider → " .. providers[picked].name, vim.log.levels.INFO)
			vim.schedule(function()
				M.select_model()
			end)
		end
	)
end

--- Spawn an ephemeral session, send one prompt, call on_done when finished.
--- Does not touch the main `state`.
function M.send_oneshot(prompt, regions, context_regions, on_done)
	local s = {
		proc = nil,
		next_id = 1,
		pending = {},
		session_id = nil,
		stdout_buf = "",
		_on_done = on_done,
	}

	local proc = vim.system(
		opts.cmd,
		{
			stdin = true,
			cwd = vim.fn.getcwd(),
			stdout = vim.schedule_wrap(function(_, data)
				if data then
					on_stdout(s, data)
				end
			end),
			stderr = vim.schedule_wrap(function(_, _) end),
		},
		vim.schedule_wrap(function(_)
			s.proc = nil
		end)
	)
	s.proc = proc

	local init = rpc_request(s, "initialize", {
		protocolVersion = 1,
		clientCapabilities = { fs = { readTextFile = true, writeTextFile = true } },
		clientInfo = { name = "lg-quick", version = "2.0.0" },
	})
	if not init then
		pcall(function()
			proc:kill(9)
		end)
		return
	end

	local sr = rpc_request(s, "session/new", { cwd = vim.fn.getcwd(), mcpServers = opts.mcp_servers })
	if not sr or not sr.sessionId then
		pcall(function()
			proc:kill(9)
		end)
		return
	end
	s.session_id = sr.sessionId

	-- Wrap on_done to also kill the ephemeral process
	s._on_done = function()
		if on_done then
			on_done()
		end
		vim.defer_fn(function()
			pcall(function()
				proc:kill(9)
			end)
		end, 500)
	end

	local messages = protocol.build_prompt(regions, context_regions or {}, prompt)
	status.start("Quick edit...")
	vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestStarted" })
	local id = s.next_id
	s.next_id = id + 1
	write(
		s,
		{ jsonrpc = "2.0", id = id, method = "session/prompt", params = { sessionId = s.session_id, prompt = messages } }
	)
end

return M
