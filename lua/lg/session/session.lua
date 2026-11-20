--- Session: orchestrator for ACP sessions via lg-acp binary.
---
--- Manages: lg-acp process lifecycle, main session, mode switching.
--- Delegates to:
---   client.lua    — socket transport
---   protocol.lua  — message building
---   subagent.lua  — ephemeral sessions (git, shell, hint, etc.)
---   restore.lua   — session listing & restore picker

local client = require("lg.session.client")
local protocol = require("lg.session.protocol")
local status = require("lg.status")
local subagent = require("lg.session.subagent")
local restore = require("lg.session.restore")
local models = require("lg.session.models")
local modes = require("lg.session.modes")
local model_check = require("lg.session.model-check")

local M = {}

local _planner_active = false
local _planner_used = false
-- The ACP mode update is asynchronous. Keep the mode we most recently asked
-- for so a delayed update from the previous switch cannot put the planner
-- state back after it has been disabled.
local _requested_mode = nil

--- @type string? main session id on the Go side
local main_session_id = nil
--- @type table? models info from session creation
local session_models = nil
--- @type vim.SystemObj? the lg-acp process
local acp_proc = nil

local opts = {}

local providers = {
	kiro = { cmd = { "kiro-cli", "acp" }, name = "Kiro" },
	opencode = { cmd = { "opencode", "acp" }, name = "OpenCode" },
	antigravity = { cmd = { "agy", "acp" }, name = "antigravity" },
}

local function resolve_mode(mode_id)
	return modes.resolve_mode(opts.provider, mode_id)
end

--- MCP servers to attach to new sessions. Kiro and OpenCode load lg's tools
--- from their own agent config. antigravity has no agent files, so lg passes
--- its servers through ACP session/new. User-configured servers take priority.
--- @param tools? string comma-separated lg mcp tool groups (default "core")
local function mcp_servers(tools)
	local servers = vim.deepcopy(opts.mcp_servers or {})
	if opts.provider ~= "antigravity" then
		return servers
	end
	local bin = require("lg.bin")
	-- agy acp has a preload race when multiple MCP servers are sent in
	-- session/new, dropping servers unpredictably. Attach a single lg mcp
	-- server scoped to the session's tool groups.
	local path = bin.find("lg")
	if path and servers.lg == nil then
		servers.lg = {
			command = path,
			args = { "mcp", "--tools=" .. (tools or "core") },
			env = { LG_SOCK = "/dev/shm/lg.sock", LG_HINT_SOCK = "/dev/shm/lg-hint.sock" },
		}
	end
	return servers
end

local state_path = "/dev/shm/lg-state.json"
local acp_sock = "/dev/shm/lg-acp.sock"

local function load_state()
	local f = io.open(state_path, "r")
	if not f then
		return {}
	end
	local ok, data = pcall(vim.json.decode, f:read("*a"))
	f:close()
	return ok and data or {}
end

local function save_state(t)
	local f = io.open(state_path, "w")
	if f then
		f:write(vim.json.encode(t))
		f:close()
	end
end

-- ── lg-acp process management ──────────────────────────────────────

local _connect_queue = nil

--- @param on_ready fun(ok: boolean)
local function ensure_acp(on_ready)
	if client.is_connected() then
		on_ready(true)
		return
	end

	client.connect(function(ok)
		if ok then
			on_ready(true)
			return
		end

		if acp_proc then
			pcall(function()
				acp_proc:kill(9)
			end)
			acp_proc = nil
		end

		local stale = vim.fn.systemlist("pgrep -f 'lg acp.*--sock' 2>/dev/null")
		for _, p in ipairs(stale) do
			p = vim.trim(p)
			if p ~= "" then
				vim.fn.system("kill -9 " .. p)
			end
		end

		vim.fn.delete(acp_sock)

		local bin = require("lg.bin").require("lg")
		if not bin then
			on_ready(false)
			return
		end

		local logfile = "/dev/shm/lg-acp.log"
		acp_proc = vim.system(
			{ "sh", "-c", bin .. " acp --provider " .. opts.provider .. " --sock " .. acp_sock .. " 2>" .. logfile },
			{ detach = true },
			function()
				acp_proc = nil
			end
		)

		local attempts = 0
		local timer = vim.uv.new_timer()
		if not timer then
			on_ready(false)
			return
		end
		timer:start(50, 50, function()
			attempts = attempts + 1
			if vim.uv.fs_stat(acp_sock) then
				timer:stop()
				timer:close()
				vim.schedule(function()
					client.connect(function(conn_ok)
						on_ready(conn_ok)
					end)
				end)
			elseif attempts > 60 then
				timer:stop()
				timer:close()
				vim.schedule(function()
					on_ready(false)
				end)
			end
		end)
	end)
end

local function refresh_session_count()
	if not client.is_connected() then
		M._session_count = 0
		return
	end
	client.send({ method = "status" }, function(resp)
		M._session_count = resp.active or 0
	end)
end

-- ── Send queue ─────────────────────────────────────────────────────

local _send_queue = {}
local _busy = false
local _has_history = false
local _chat_active = false
local _annotate_active = false

local _tool_hint_sent = false
local ANTIGRAVITY_TOOL_HINT = "[Use read_buffer, lg_grep, lg_glob, lg_write_file, paint_edit, and lg_run instead of built-in file/shell tools.]\n\n"

local function maybe_prepend_tool_hint(messages)
	if opts.provider ~= "antigravity" or _has_history or _tool_hint_sent then
		return messages
	end
	_tool_hint_sent = true
	if messages[1] and messages[1].type == "text" then
		messages[1] = { type = "text", text = ANTIGRAVITY_TOOL_HINT .. messages[1].text }
	end
	return messages
end

local function flush_send_queue()
	if #_send_queue == 0 then
		return
	end
	local next_fn = table.remove(_send_queue, 1)
	next_fn()
end

-- ── Connect ────────────────────────────────────────────────────────

local _connect_retried = nil

--- @param on_ready fun(session_id: string?)
local function connect(on_ready)
	if main_session_id and client.is_connected() then
		on_ready(main_session_id)
		return
	end

	if _connect_queue then
		table.insert(_connect_queue, on_ready)
		return
	end
	_connect_queue = { on_ready }

	local function flush(sid)
		local q = _connect_queue
		_connect_queue = nil
		for _, cb in ipairs(q) do
			cb(sid)
		end
	end

	status.start("Connecting...")

	ensure_acp(function(ok)
		if not ok then
			status.stop("Connection failed")
			flush(nil)
			return
		end

		M._setup_event_handlers()

		client.create_session(vim.fn.getcwd(), mcp_servers(), function(resp)
			if resp.error then
				if not _connect_retried then
					_connect_retried = true
					client.disconnect()
					vim.fn.delete(acp_sock)
					if acp_proc then
						pcall(function()
							acp_proc:kill(9)
						end)
						acp_proc = nil
					end
					local q = _connect_queue
					_connect_queue = nil
					for _, cb in ipairs(q) do
						connect(cb)
					end
					return
				end
				_connect_retried = nil
				status.stop("Session failed: " .. resp.error)
				flush(nil)
				return
			end
			_connect_retried = nil

			main_session_id = resp.session_id
			if resp.models then
				session_models = resp.models
				-- This is the provider's initial choice, before lg restores any
				-- user-selected model. Keep it available as a distinct picker item.
				session_models.defaultModelId = session_models.currentModelId
				-- Surface stale pinned models now, rather than mid-turn when an
				-- agent switch fails with an opaque error.
				model_check.validate_agents(session_models, opts.provider)
			end

			refresh_session_count()

			-- Restore the saved model even when it's missing from this first
			-- list: opencode only adds some models (github-copilot/auto) in a
			-- later config_option_update.
			local saved = load_state()
			local function finish_connect()
				client.set_mode(main_session_id, resolve_mode("lg"))
				status.stop("Session ready")
				flush(main_session_id)
			end

			if saved.model and not saved.use_default_model and session_models then
				require("lg.session.model-select").set_confirmed(main_session_id, saved.model, {
					on_done = function(ok)
						if ok and session_models then
							session_models.currentModelId = saved.model
						end
						finish_connect()
					end,
				})
			else
				finish_connect()
			end
		end)
	end)
end

-- ── Event handlers ─────────────────────────────────────────────────

function M._setup_event_handlers()
	client.clear_handlers()

	client.on("text", function(ev)
		if ev.session_id ~= main_session_id then
			return
		end
		if ev.text then
			require("lg.ui.window").append_agent_text(ev.text)
		end
	end)

	client.on("tool_call", function(ev)
		if ev.session_id ~= main_session_id then
			return
		end
		if M._restoring then
			return
		end
		status.update("Tool: " .. (ev.text or "unknown"))
		require("lg.ui.window").add_tool(ev.text or "unknown")
		vim.api.nvim_exec_autocmds("User", { pattern = "LgToolCall", data = { title = ev.text } })
	end)

	client.on("tool_error", function(ev)
		if ev.session_id ~= main_session_id then
			return
		end
		if M._restoring then
			return
		end
		local msg = ev.text or "unknown"
		status.flash("Tool failed: " .. msg)
		require("lg.ui.window").add_status("Tool failed: " .. msg)
	end)

	-- The agent logged an error (e.g. usage limit) without ending the turn.
	-- It may still recover, so let the user choose. Covers subagent sessions
	-- too: aborting emits prompt_error, which their own handlers clean up.
	local agent_errors = {} -- session_id → latest error, while the turn is live
	client.on("agent_error", function(ev)
		local sid = ev.session_id
		local asking = agent_errors[sid] ~= nil
		agent_errors[sid] = ev.error or "unknown error"
		status.update("Agent error: " .. agent_errors[sid])
		if asking then
			return
		end
		vim.ui.select({ "Cancel request", "Keep waiting" }, {
			prompt = "lg: agent error: " .. agent_errors[sid],
		}, function(choice)
			local err = agent_errors[sid]
			-- nil when the turn already ended while the prompt was open
			if err and choice == "Cancel request" then
				client.abort_prompt(sid, err)
			end
		end)
	end)
	local function clear_agent_error(ev)
		agent_errors[ev.session_id] = nil
	end
	client.on("prompt_done", clear_agent_error)
	client.on("prompt_error", clear_agent_error)

	client.on("prompt_done", function(ev)
		if ev.session_id ~= main_session_id then
			return
		end
		_has_history = true
		status.stop("Done")
		vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestFinished" })
		if M._on_done then
			local cb = M._on_done
			M._on_done = nil
			cb()
		end
		-- If the planner queued a handoff during this turn, switch to
		-- lg-chat now (agent is idle) and re-send the plan for execution.
		if M._pending_handoff then
			local plan = M._pending_handoff
			M._pending_handoff = nil
			M._run_handoff(plan)
		end
	end)

	client.on("prompt_error", function(ev)
		if ev.session_id ~= main_session_id then
			return
		end
		local explanation = model_check.explain_error(ev.error, session_models, opts.provider)
		if explanation then
			status.stop("Model unavailable")
			vim.notify("lg: " .. explanation, vim.log.levels.ERROR)
		else
			status.stop("Error: " .. (ev.error or "unknown"))
		end
		require("lg.ui.window").add_status("Request failed: " .. (explanation or ev.error or "unknown"))
		vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestFinished" })
		-- The turn is over, so run the completion callback anyway: it restores the
		-- agent mode, clears the busy flag and flushes the send queue. Skipping it
		-- would leave the session wedged in the failed mode with queued prompts
		-- that never fire.
		if M._on_done then
			local cb = M._on_done
			M._on_done = nil
			cb()
		else
			_busy = false
			flush_send_queue()
		end
	end)

	client.on("permission_request", function(ev)
		if ev.session_id ~= main_session_id then
			return
		end
		local data = ev.data
		if type(data) == "string" then
			local ok2, parsed = pcall(vim.json.decode, data)
			if ok2 then
				data = parsed
			end
		end
		local title = data.title or "Permission request"
		local rpc_id = data.rpc_id

		require("lg.ui.approval").permission(title, data.options, function(oid, allowed)
			if ev.session_id then
				client.respond_permission(ev.session_id, rpc_id, oid)
			end
			status.update(allowed and ("Approved: " .. title) or ("Rejected: " .. title))
		end)
	end)

	client.on("permission_auto", function(ev)
		status.update("Approved: " .. (ev.text or ""))
	end)

	client.on("context_usage", function(ev)
		if ev.session_id ~= main_session_id then
			return
		end
		local data = ev.data
		if type(data) == "string" then
			local ok2, parsed = pcall(vim.json.decode, data)
			if ok2 then
				data = parsed
			end
		end
		if data and data.context_pct then
			require("lg.ui.window").set_context_pct(data.context_pct)
		end
	end)

	client.on("metering", function(ev)
		if ev.session_id ~= main_session_id then
			return
		end
		local data = ev.data
		if type(data) == "string" then
			local ok2, parsed = pcall(vim.json.decode, data)
			if ok2 then
				data = parsed
			end
		end
		if not data then
			return
		end
		require("lg.ui.window").add_metering(data)
	end)

	client.on("compaction", function(ev)
		if ev.session_id ~= main_session_id then
			return
		end
		status.update("Compacting context…")
	end)

	client.on("commands_available", function(ev)
		if ev.session_id ~= main_session_id then
			return
		end
		local data = ev.data
		if type(data) == "string" then
			local ok2, parsed = pcall(vim.json.decode, data)
			if ok2 then
				data = parsed
			end
		end
		local cmds = data and data.commands or {}
		local names = {}
		for _, c in ipairs(cmds) do
			names[#names + 1] = c.name or c
		end
		if #names > 0 then
			M._available_commands = names
		end
	end)

	client.on("clear_status", function(ev)
		if ev.session_id ~= main_session_id then
			return
		end
		status.update("Clearing session…")
	end)

	client.on("fs_read", function(ev)
		status.update("Read: " .. vim.fn.fnamemodify(ev.text or "", ":t"))
	end)

	client.on("agent_switched", function(ev)
		if ev.session_id ~= main_session_id then
			return
		end
		local data = ev.data
		if type(data) == "string" then
			local ok2, parsed = pcall(vim.json.decode, data)
			if ok2 then
				data = parsed
			end
		end
		if type(data) ~= "table" then
			return
		end
		local new_agent = data.agentName
		local prev = data.previousAgentName
		if _requested_mode and new_agent ~= _requested_mode then
			return
		end
		if new_agent == _requested_mode then
			_requested_mode = nil
		end
		local plan_mode = resolve_mode("lg-plan")
		local chat_mode = resolve_mode("lg-chat")
		_planner_active = (new_agent == plan_mode)
		local win = require("lg.ui.window")
		if _planner_active then
			win.add_status("▶ plan mode (" .. (prev or "?") .. " → " .. plan_mode .. ")")
		elseif new_agent == chat_mode and prev == plan_mode then
			-- handoff landing (message already printed by _run_handoff)
			win.refresh()
		else
			win.add_status("agent: " .. (new_agent or "?"))
		end
		vim.api.nvim_exec_autocmds("User", {
			pattern = "LgAgentSwitched",
			data = { agent = new_agent, previous = prev },
		})
	end)
end

-- ── Setup ──────────────────────────────────────────────────────────

function M.setup(user_opts)
	opts = vim.tbl_deep_extend("force", {
		timeout = 30000,
		mcp_servers = {},
		provider = "kiro",
	}, user_opts or {})

	local saved = load_state()
	if saved.provider and providers[saved.provider] then
		opts.provider = saved.provider
	end

	-- Wire up models module (provider/model selection needs session internals)
	models.init({
		connect = connect,
		get_models = function()
			return session_models
		end,
		set_models = function(m)
			-- A later get_models response may reflect the restored model. Preserve
			-- the provider default captured when this session was created.
			m.defaultModelId = m.defaultModelId
				or (session_models and session_models.defaultModelId)
				or m.currentModelId
			session_models = m
		end,
		set_current_model = function(id)
			if session_models then
				session_models.currentModelId = id
			end
		end,
		reset = function()
			M.reset()
		end,
		clear = function()
			M.clear()
		end,
		save_state = save_state,
		load_state = load_state,
		get_provider = function()
			return opts.provider
		end,
		set_provider = function(p)
			opts.provider = p
		end,
		set_on_done = function(fn)
			M._on_done = fn
		end,
		set_busy = function(b)
			_busy = b
		end,
		get_main_session_id = function()
			return main_session_id
		end,
		get_has_history = function()
			return _has_history
		end,
		providers = providers,
	})

	-- Wire up subagent module
	subagent._ensure_acp = ensure_acp
	subagent._resolve_mode = resolve_mode
	subagent._mcp_servers = mcp_servers
	subagent._opts = function()
		return opts
	end

	-- Wire up restore module
	restore._ensure_acp = ensure_acp
	restore._resolve_mode = resolve_mode
	restore._get_sid = function()
		return main_session_id
	end
	restore._set_sid = function(sid)
		main_session_id = sid
	end
	restore._setup_event_handlers = function()
		M._setup_event_handlers()
	end
	restore._refresh_count = refresh_session_count
	restore._set_models = function(m)
		session_models = m
	end
	restore._get_provider = function()
		return opts.provider or "kiro"
	end

	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("lg.session.session", { clear = true }),
		callback = function()
			M.clear()
		end,
	})
end

-- ── Public API ─────────────────────────────────────────────────────

function M.send(prompt, regions, context_regions, on_done, lsp_context, tsc_context)
	connect(function(sid)
		if not sid then
			return
		end

		local function do_send()
			_busy = true
			local token = nil
			if #regions > 0 then
				local svr = require("lg.session.server")
				token = svr.create_token(regions)
			end

			local messages =
				protocol.build_prompt(regions, context_regions or {}, prompt, lsp_context, tsc_context, token)

			status.start("Thinking...")
			vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestStarted" })

			M._on_done = function()
				_busy = false
				if on_done then
					on_done()
				end
				flush_send_queue()
			end

			if _planner_active then
				_planner_used = true
			end
			client.prompt(sid, maybe_prepend_tool_hint(messages))
		end

		if _busy then
			table.insert(_send_queue, do_send)
			status.update("Queued (waiting for current request)...")
		else
			do_send()
		end
	end)
end

function M.send_chat(prompt, on_done)
	connect(function(sid)
		if not sid then
			return
		end

		local function do_send()
			local target_mode = _planner_active and "lg-plan" or "lg-chat"
			local return_mode = _planner_active and "lg-plan" or "lg"

			if not _planner_active then
				require("lg.ui.window").add_status("Switching to chat mode")
			end
			client.set_mode(sid, resolve_mode(target_mode))

			local messages = protocol.build_prompt({}, {}, prompt)

			status.start("Thinking...")
			vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestStarted" })

			_chat_active = not _planner_active
			M._on_done = function()
				_chat_active = false
				if not _planner_active then
					require("lg.ui.window").add_status("Switching to paint mode")
				end
				client.set_mode(sid, resolve_mode(return_mode))
				_busy = false
				if on_done then
					on_done()
				end
				flush_send_queue()
			end

			_busy = true
			if _planner_active then
				_planner_used = true
			end
			client.prompt(sid, maybe_prepend_tool_hint(messages))
		end

		if _busy then
			table.insert(_send_queue, do_send)
			status.update("Queued (waiting for current request)...")
		else
			do_send()
		end
	end)
end

--- Send on main session with a temporary mode switch (hint, suggest, help).
--- @param config { mode_id: string, scope?: string }
function M.send_mode(config, prompt, regions, context_regions, on_done)
	connect(function(sid)
		if not sid then
			return
		end

		local function do_send()
			client.set_mode(sid, resolve_mode(config.mode_id))

			local all_ctx = {}
			for _, r in ipairs(regions) do
				all_ctx[#all_ctx + 1] = r
			end
			for _, r in ipairs(context_regions or {}) do
				all_ctx[#all_ctx + 1] = r
			end
			local has_scope = #regions > 0
			local extra = (config.scope and has_scope) and { scope = config.scope } or nil
			local messages = protocol.build_prompt({}, all_ctx, prompt, nil, nil, nil, extra)
			vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestStarted" })

			_busy = true
			M._on_done = function()
				client.set_mode(sid, resolve_mode("lg"))
				_busy = false
				if on_done then
					on_done()
				end
				flush_send_queue()
			end

			client.prompt(sid, maybe_prepend_tool_hint(messages))
		end

		if _busy then
			table.insert(_send_queue, do_send)
			status.update("Queued (waiting for current request)...")
		else
			do_send()
		end
	end)
end

function M.reset()
	_connect_queue = nil
	_send_queue = {}
	_busy = false
	_has_history = false
	_tool_hint_sent = false
	_chat_active = false
	_annotate_active = false
	M._on_done = nil
	M._session_count = 0
	require("lg.session.server").clear_tokens()
	if main_session_id and client.is_connected() then
		client.destroy_session(main_session_id)
	end
	main_session_id = nil
	session_models = nil
	-- Process + connection stay alive; next send triggers create_session
end

function M.clear()
	_connect_queue = nil
	_send_queue = {}
	_busy = false
	_has_history = false
	_tool_hint_sent = false
	_chat_active = false
	_annotate_active = false
	M._on_done = nil
	M._session_count = 0
	require("lg.session.server").clear_tokens()
	if main_session_id then
		client.destroy_session(main_session_id)
		main_session_id = nil
	end
	session_models = nil
	client.terminate()
	client.disconnect()
	if acp_proc then
		pcall(function()
			acp_proc:kill(9)
		end)
		acp_proc = nil
	end
	vim.fn.delete(acp_sock)
end

function M.kill()
	if not main_session_id then
		return
	end
	client.cancel(main_session_id)
	_busy = false
	_chat_active = false
	_annotate_active = false
	M._on_done = nil
end

function M.allows_write_file()
	return _chat_active
end

function M.set_annotate_active(active)
	_annotate_active = active and true or false
end

function M.allows_annotate()
	return _annotate_active
end

function M.is_active()
	return main_session_id ~= nil and client.is_connected()
end

function M.is_connected()
	return acp_proc ~= nil and client.is_connected()
end

function M.session_count()
	if not acp_proc or not client.is_connected() then
		return 0
	end
	return M._session_count or 0
end

function M.is_busy()
	return _busy
end

-- Wrappers delegating to models.lua (keep these callable on the session module).
function M.select_model()
	models.select_model()
end

function M.current_model()
	return models.current_model()
end

function M.current_provider()
	return models.current_provider()
end

--- Connect if needed so the provider reports its model, then call cb(model_id).
--- @param cb fun(model: string?)
function M.fetch_model(cb)
	connect(function()
		cb(M.current_model())
	end)
end

function M.select_provider()
	models.select_provider()
end

--- Call a kiro extension method (e.g. "_kiro/session/compact") on the main
--- session, connecting first if needed.
--- @param method string
--- @param callback fun(resp: table)
function M.rpc(method, callback)
	connect(function(sid)
		if not sid then
			callback({ error = "no session" })
			return
		end
		client.rpc_call(sid, method, { sessionId = sid }, function(resp)
			vim.schedule(function()
				callback(resp)
			end)
		end)
	end)
end

function M.compact()
	connect(function(sid)
		if not sid then
			return
		end
		status.start("Compacting…")
		local win = require("lg.ui.window")
		local spin = require("lg.spinner.spinners").start({})
		_busy = true

		-- antigravity exposes compact as an advertised slash command, run by
		-- sending it as prompt text. Kiro uses its extension method.
		if opts.provider == "antigravity" then
			M._on_done = function()
				spin:stop()
				_busy = false
				status.stop("Compacted")
				win.add_status("Context compacted")
				flush_send_queue()
			end
			client.prompt(sid, { { type = "text", text = "/compact" } })
			return
		end

		M.rpc("_kiro/session/compact", function(resp)
			spin:stop()
			_busy = false
			client.set_mode(sid, resolve_mode("lg"))
			if resp and resp.ok then
				status.stop("Compacted")
				win.add_status("Context compacted")
			else
				local err = (resp and resp.error) or "compact failed"
				status.stop("Compact failed")
				win.add_status("Compact failed: " .. err)
			end
			flush_send_queue()
		end)
	end)
end

--- Run a kiro slash command. Kiro v3 has no generic command API over ACP,
--- so only commands lg maps to a v3 method are supported.
--- @param command string e.g. "compact" or "/usage"
function M.execute_command(command)
	local name = command:gsub("^/", "")
	if name == "compact" then
		M.compact()
	elseif name == "usage" then
		require("lg.usage").show()
	elseif opts.provider == "antigravity" then
		-- antigravity runs its advertised slash commands from prompt text.
		M.send_chat("/" .. name)
	else
		vim.notify("lg: /" .. name .. " isn't available through Kiro v3 ACP", vim.log.levels.WARN)
	end
end

function M.available_commands()
	return M._available_commands or {}
end

function M.info()
	local lines = {}
	local function add(s)
		lines[#lines + 1] = s
	end

	add("Provider: " .. (providers[opts.provider] and providers[opts.provider].name or opts.provider))
	add("Model: " .. (M.current_model() or "default"))
	add("Session: " .. (main_session_id and "active" or "none"))
	add("Backend: lg-acp (Go)")
	add("")

	local agents_dir = vim.fn.expand("~/.kiro/agents")
	local agent_files = vim.fn.glob(agents_dir .. "/*.json", false, true)
	for _, path in ipairs(agent_files) do
		local f = io.open(path, "r")
		if f then
			local ok, cfg = pcall(vim.json.decode, f:read("*a"))
			f:close()
			if ok and cfg.name then
				local mcps = {}
				for name, _ in pairs(cfg.mcpServers or {}) do
					mcps[#mcps + 1] = name
				end
				add(
					string.format(
						"Agent [%s]: model=%s  mcps=%s  tools=%s",
						cfg.name,
						cfg.model or "default",
						#mcps > 0 and table.concat(mcps, ",") or "none",
						cfg.tools and table.concat(cfg.tools, ",") or "none"
					)
				)
			end
		end
	end

	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

-- ── Planner ────────────────────────────────────────────────────────

-- Called from lua/lg/session/server.lua when the lg-plan agent invokes the
-- handoff_to_chat MCP tool. Stashes the plan so prompt_done can act on it.
function M.queue_handoff(plan)
	M._pending_handoff = plan
end

-- Switch agent to lg-chat and re-send the plan as a new prompt so execution
-- runs on lg-chat (which uses lg_write_file = buffer-only diff review).
function M._run_handoff(plan)
	if not main_session_id or not client.is_connected() then
		return
	end
	_planner_active = false
	_planner_used = false
	_requested_mode = resolve_mode("lg-chat")
	local win = require("lg.ui.window")
	win.add_status("◀ plan confirmed — handing off to lg-chat")
	client.set_mode(main_session_id, resolve_mode("lg-chat"), function(resp)
		if not (resp and resp.ok) then
			win.add_status("handoff failed: " .. (resp and resp.error or "unknown"))
			return
		end
		local prompt = "Execute this plan now using lg_write_file. Read the file first if you need to verify old_text matches, but do not re-plan or re-ask for confirmation — the user already approved.\n\n--- PLAN ---\n"
			.. plan
		status.start("Executing plan...")
		_chat_active = true
		M._on_done = function()
			_chat_active = false
			_busy = false
			status.stop("Plan executed")
			flush_send_queue()
		end
		_busy = true
		client.prompt(main_session_id, { { type = "text", text = prompt } })
	end)
end

function M.set_planner(enabled, callback)
	local had_plan_turn = not enabled and _planner_used
	_planner_active = enabled
	_planner_used = false
	_requested_mode = resolve_mode(enabled and "lg-plan" or "lg-chat")
	connect(function(sid)
		if not sid then
			_requested_mode = nil
			if callback then
				callback(false)
			end
			return
		end
		client.set_mode(sid, resolve_mode(enabled and "lg-plan" or "lg-chat"), function(resp)
			if
				not (resp and resp.ok == true)
				and _requested_mode == resolve_mode(enabled and "lg-plan" or "lg-chat")
			then
				_requested_mode = nil
			end
			if callback then
				callback(resp and resp.ok == true)
			end
			if resp and resp.ok == true and not enabled and had_plan_turn then
				-- A plan agent may keep behaving as a planner until it receives a
				-- turn in its new mode. Send that transition explicitly instead of
				-- requiring the user to type "exit plan mode" manually.
				local messages = protocol.build_prompt(
					{},
					{},
					"Exit plan mode now. You are the chat agent. Confirm that plan mode has been exited and that you are ready to make changes directly."
				)
				_busy = true
				status.start("Exiting plan mode...")
				vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestStarted" })
				M._on_done = function()
					_busy = false
					flush_send_queue()
				end
				client.prompt(sid, messages)
			end
		end)
	end)
end

function M.is_planner_active()
	return _planner_active
end
function M.kill_planner()
	_planner_active = false
	_planner_used = false
	_requested_mode = nil
end

-- ── Mode sends (hint/suggest/help on main session) ────────────────

function M.send_hint(prompt, regions, context_regions, on_done)
	M.send_mode({ mode_id = "reviewer", scope = "hints" }, prompt, regions, context_regions, on_done)
end

function M.send_suggest(prompt, regions, context_regions, on_done)
	M.send_mode({ mode_id = "suggester", scope = "suggestions" }, prompt, regions, context_regions, on_done)
end

function M.send_help(prompt, regions, context_regions, on_done)
	M.send_mode({ mode_id = "helper", scope = "help" }, prompt, regions, context_regions, on_done)
end

function M.send_ask(prompt, regions, context_regions, on_done)
	M.send_mode({ mode_id = "asker" }, prompt, regions, context_regions, on_done)
end

-- ── Subagent delegates ─────────────────────────────────────────────

function M.send_oneshot(prompt, regions, context_regions, on_done)
	subagent.send_oneshot(prompt, regions, context_regions, on_done)
end

function M.send_shell_subagent(prompt, on_done)
	subagent.send_shell(prompt, on_done)
end

function M.send_git_subagent(prompt, on_done)
	subagent.send_git(prompt, on_done)
end

function M.send_devlens_subagent(prompt, on_done)
	subagent.send_devlens(prompt, on_done)
end

function M.send_quick_chat(prompt, on_done)
	subagent.send_quick_chat(prompt, on_done, function(o)
		models.set_override(o)
	end, function()
		models.clear_override()
	end)
end

function M.send_hint_subagent(prompt, regions, context_regions, on_done)
	subagent.send_mode_subagent(
		{ mode_id = "reviewer", scope = "hints", tools = "core,hint", label = "Reviewing (subagent)" },
		prompt,
		regions,
		context_regions,
		on_done
	)
end

function M.send_suggest_subagent(prompt, regions, context_regions, on_done)
	subagent.send_mode_subagent(
		{ mode_id = "suggester", scope = "suggestions", tools = "core,hint", label = "Suggesting (subagent)" },
		prompt,
		regions,
		context_regions,
		on_done
	)
end

function M.send_help_subagent(prompt, regions, context_regions, on_done)
	subagent.send_mode_subagent(
		{ mode_id = "helper", scope = "help", tools = "core,hint", label = "Help (subagent)" },
		prompt,
		regions,
		context_regions,
		on_done
	)
end

function M.send_info_subagent(prompt, regions, context_regions, on_done)
	subagent.send_mode_subagent(
		{ mode_id = "lg-info", label = "Info paint (subagent)", track_tool_errors = false },
		prompt,
		regions,
		context_regions,
		on_done
	)
end

-- ── Restore delegate ───────────────────────────────────────────────

function M.restore_session()
	restore.pick()
end

return M
