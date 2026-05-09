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

local M = {}

local _planner_active = false

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
}

local opencode_modes = {
	lg = "build",
	["lg-chat"] = "build",
	["lg-plan"] = "plan",
	["lg-oneshot"] = "build",
	["lg-info"] = "build",
	reviewer = "plan",
	suggester = "plan",
	helper = "plan",
	asker = "plan",
	fullstack = "build",
	kiro_default = "build",
	kiro_planner = "plan",
}

local function resolve_mode(mode_id)
	if opts.provider == "opencode" then
		return opencode_modes[mode_id] or "build"
	end
	return mode_id
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

		local stale = vim.fn.systemlist("pgrep -f 'lg-acp.*--sock' 2>/dev/null")
		for _, p in ipairs(stale) do
			p = vim.trim(p)
			if p ~= "" then
				vim.fn.system("kill -9 " .. p)
			end
		end

		vim.fn.delete(acp_sock)

		local plugin_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h:h")
		local bin = plugin_dir .. "/acp/lg-acp"

		local logfile = "/dev/shm/lg-acp.log"
		acp_proc = vim.system(
			{ "sh", "-c", bin .. " --provider " .. opts.provider .. " --sock " .. acp_sock .. " 2>" .. logfile },
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

		client.create_session(vim.fn.getcwd(), opts.mcp_servers, function(resp)
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
			end

			refresh_session_count()

			local saved = load_state()
			if saved.model and session_models then
				for _, m in ipairs(session_models.availableModels or {}) do
					if m.modelId == saved.model then
						client.set_model(main_session_id, saved.model)
						session_models.currentModelId = saved.model
						break
					end
				end
			end

			client.set_mode(main_session_id, resolve_mode("lg"))
			status.stop("Session ready")
			flush(main_session_id)
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
		status.flash("Tool failed: " .. (ev.text or "unknown"))
	end)

	client.on("prompt_done", function(ev)
		if ev.session_id ~= main_session_id then
			return
		end
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
		status.stop("Error: " .. (ev.error or "unknown"))
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
		local options = data.options or {}

		local reject_id, allow_id
		for _, opt in ipairs(options) do
			if not reject_id and (opt.kind == "reject_once" or opt.kind == "reject_always") then
				reject_id = opt.optionId
			end
			if not allow_id and (opt.kind == "allow_always" or opt.kind == "allow_once") then
				allow_id = opt.optionId
			end
		end

		vim.ui.select({ "Allow", "Reject" }, { prompt = title .. "?" }, function(choice)
			local oid = choice == "Allow" and allow_id or reject_id or allow_id
			if oid and ev.session_id then
				client.respond_permission(ev.session_id, rpc_id, oid)
			end
			status.update(choice == "Allow" and ("Approved: " .. title) or ("Rejected: " .. title))
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
		status.update("Reading: " .. vim.fn.fnamemodify(ev.text or "", ":t"))
	end)

	client.on("fs_write", function(ev)
		local path = ev.text or ""
		status.update("Writing: " .. vim.fn.fnamemodify(path, ":t"))
		vim.schedule(function()
			local resolved = vim.fn.fnamemodify(path, ":p")
			for _, buf in ipairs(vim.api.nvim_list_bufs()) do
				if vim.api.nvim_buf_is_loaded(buf) then
					local bname = vim.api.nvim_buf_get_name(buf)
					if bname == resolved or bname == path then
						vim.bo[buf].autoread = true
						vim.cmd("checktime " .. buf)
					end
				end
			end
		end)
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
		_planner_active = (new_agent == "lg-plan")
		local win = require("lg.ui.window")
		if _planner_active then
			win.add_status("▶ plan mode (" .. (prev or "?") .. " → lg-plan)")
		elseif new_agent == "lg-chat" and prev == "lg-plan" then
			-- handoff landing (message already printed by _run_handoff)
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

	-- Wire up subagent module
	subagent._ensure_acp = ensure_acp
	subagent._resolve_mode = resolve_mode
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

			client.prompt(sid, messages)
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

			M._on_done = function()
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
			client.prompt(sid, messages)
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

			client.prompt(sid, messages)
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
	M._on_done = nil
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

function M.select_model()
	connect(function(sid)
		if not sid or not session_models then
			vim.notify("lg: no models available", vim.log.levels.WARN)
			return
		end

		local names = {}
		for _, m in ipairs(session_models.availableModels or {}) do
			local label = m.modelId
			if m.modelId == session_models.currentModelId then
				label = label .. " (current)"
			end
			table.insert(names, label)
		end

		vim.ui.select(
			names,
			{ prompt = "lg model (current: " .. (session_models.currentModelId or "?") .. "):" },
			function(choice)
				if not choice then
					return
				end
				local model_id = choice:gsub(" %(current%)$", "")
				client.set_model(sid, model_id)
				session_models.currentModelId = model_id
				save_state({ provider = opts.provider, model = model_id })
				vim.notify("lg: model → " .. model_id, vim.log.levels.INFO)
			end
		)
	end)
end

local ephemeral_override = nil

function M.current_model()
	if ephemeral_override then
		return ephemeral_override.model
	end
	if session_models then
		return session_models.currentModelId
	end
	local saved = load_state()
	return saved.model
end

function M.current_provider()
	if ephemeral_override then
		return ephemeral_override.provider
	end
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

	vim.ui.select(
		vim.tbl_map(function(n)
			return n.label
		end, names),
		{ prompt = "lg provider (current: " .. (providers[opts.provider].name or "?") .. "):" },
		function(choice, idx)
			if not choice or not idx then
				return
			end
			local picked = names[idx].key
			if picked == opts.provider and main_session_id then
				return
			end
			opts.provider = picked
			M.clear()
			save_state({ provider = picked, model = M.current_model() })
			vim.notify("lg: provider → " .. providers[picked].name, vim.log.levels.INFO)
			vim.schedule(function()
				M.select_model()
			end)
		end
	)
end

function M.compact()
	connect(function(sid)
		if not sid then
			return
		end
		status.start("Compacting…")
		local win = require("lg.ui.window")
		local spin = require("lg.spinner.spinners").start({})
		M._on_done = function()
			spin:stop()
			_busy = false
			client.set_mode(sid, resolve_mode("lg"))
			status.stop("Compacted")
			win.add_status("Context compacted")
			flush_send_queue()
		end
		_busy = true
		client.prompt(sid, { { type = "text", text = "/compact" } })
	end)
end

function M.run_command(command, on_done)
	if not main_session_id or not client.is_connected() then
		if on_done then on_done() end
		return
	end
	client.execute_command(main_session_id, command, function()
		if on_done then vim.schedule(on_done) end
	end)
end

function M.execute_command(command, callback)
	connect(function(sid)
		if not sid then
			return
		end
		if command:sub(1, 1) ~= "/" then
			command = "/" .. command
		end
		client.execute_command(sid, command, function(resp)
			vim.schedule(function()
				if callback then
					callback(resp)
				elseif resp.ok and resp.data then
					local data = resp.data
					if type(data) == "string" then
						local ok, parsed = pcall(vim.json.decode, data)
						if ok then data = parsed end
					end
					if data.message then
						vim.notify(data.message, vim.log.levels.INFO)
					end
				elseif resp.error then
					vim.notify(resp.error, vim.log.levels.ERROR)
				end
			end)
		end)
	end)
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
	local win = require("lg.ui.window")
	win.add_status("◀ plan confirmed — handing off to lg-chat")
	client.execute_command(main_session_id, "agent", { agentName = "lg-chat" }, function(resp)
		if not (resp and resp.ok) then
			win.add_status("handoff failed: " .. (resp and resp.error or "unknown"))
			return
		end
		local prompt = "Execute this plan now using lg_write_file. Read the file first if you need to verify old_text matches, but do not re-plan or re-ask for confirmation — the user already approved.\n\n--- PLAN ---\n" .. plan
		status.start("Executing plan...")
		M._on_done = function()
			_busy = false
			status.stop("Plan executed")
			flush_send_queue()
		end
		_busy = true
		client.prompt(main_session_id, { { type = "text", text = prompt } })
	end)
end

function M.set_planner(enabled, callback)
	_planner_active = enabled
	connect(function(sid)
		if not sid then
			if callback then
				callback(false)
			end
			return
		end
		if opts.provider == "kiro" then
			-- Switch agent via kiro's own command so we get the full
			-- agent/switched + commands/available refresh.
			client.execute_command(sid, "agent", { agentName = enabled and "lg-plan" or "lg-chat" }, function(resp)
				if callback then
					callback(resp and resp.ok == true)
				end
			end)
		else
			-- Opencode has no kiro extension; fall back to set_mode
			client.set_mode(sid, resolve_mode(enabled and "kiro_planner" or "kiro_default"))
			if callback then
				callback(true)
			end
		end
	end)
end

function M.is_planner_active()
	return _planner_active
end
function M.kill_planner()
	_planner_active = false
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
		ephemeral_override = o
	end, function()
		ephemeral_override = nil
	end)
end

function M.send_hint_subagent(prompt, regions, context_regions, on_done)
	subagent.send_mode_subagent(
		{ mode_id = "reviewer", scope = "hints", label = "Reviewing (subagent)" },
		prompt,
		regions,
		context_regions,
		on_done
	)
end

function M.send_suggest_subagent(prompt, regions, context_regions, on_done)
	subagent.send_mode_subagent(
		{ mode_id = "suggester", scope = "suggestions", label = "Suggesting (subagent)" },
		prompt,
		regions,
		context_regions,
		on_done
	)
end

function M.send_help_subagent(prompt, regions, context_regions, on_done)
	subagent.send_mode_subagent(
		{ mode_id = "helper", scope = "help", label = "Help (subagent)" },
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
