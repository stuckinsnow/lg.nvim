--- Session: orchestrator for ACP sessions via lg-acp binary.
---
--- Manages: lg-acp process lifecycle, main session, subagent dispatch.
--- Delegates to: client.lua (socket transport), protocol.lua (message building).
--- The Go binary handles: ACP subprocess, NDJSON framing, session state machine,
--- permission auto-approval, fs operations.

local client = require("lg.session.client")
local protocol = require("lg.session.protocol")
local status = require("lg.status")

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

--- Map kiro mode IDs to opencode equivalents.
--- Opencode only has "build" and "plan" as ACP modes.
local opencode_modes = {
	lg = "build",
	["lg-chat"] = "build",
	["lg-oneshot"] = "build",
	["lg-info"] = "build",
	reviewer = "plan",
	suggester = "plan",
	helper = "plan",
	fullstack = "build",
	kiro_default = "build",
	kiro_planner = "plan",
}

--- Resolve a mode ID for the current provider.
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

	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("lg.session.session", { clear = true }),
		callback = function()
			M.clear()
		end,
	})
end

-- ── lg-acp process management ──────────────────────────────────────

local _connect_queue = nil

--- Ensure lg-acp binary is running and we have a socket connection.
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
			pcall(function() acp_proc:kill(9) end)
			acp_proc = nil
		end

		-- Clean up stale socket
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
				vim.schedule(function() on_ready(false) end)
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

--- Ensure we have a main session. Queues concurrent callers.
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
				-- Retry once: disconnect, respawn, reconnect
				if not _connect_retried then
					_connect_retried = true
					client.disconnect()
					vim.fn.delete(acp_sock)
					if acp_proc then
						pcall(function() acp_proc:kill(9) end)
						acp_proc = nil
					end
					local q = _connect_queue
					_connect_queue = nil
					-- Re-enter connect for each queued callback
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

			-- Restore persisted model
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

			-- Switch to lg agent mode
			client.set_mode(main_session_id, resolve_mode("lg"))

			status.stop("Session ready")

			flush(main_session_id)
		end)
	end)
end

--- Set up event handlers for streamed events from lg-acp.
function M._setup_event_handlers()
	client.clear_handlers()

	client.on("text", function(ev)
		if ev.text then
			require("lg.ui.window").append_agent_text(ev.text)
		end
	end)

	client.on("tool_call", function(ev)
		if M._restoring then return end
		status.update("Tool: " .. (ev.text or "unknown"))
		require("lg.ui.window").add_tool(ev.text or "unknown")
		vim.api.nvim_exec_autocmds("User", { pattern = "LgToolCall", data = { title = ev.text } })
	end)

	client.on("tool_error", function(ev)
		status.flash("Tool failed: " .. (ev.text or "unknown"))
	end)

	client.on("prompt_done", function()
		status.stop("Done")
		vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestFinished" })
		if M._on_done then
			local cb = M._on_done
			M._on_done = nil
			cb()
		end
	end)

	client.on("prompt_error", function(ev)
		status.stop("Error: " .. (ev.error or "unknown"))
	end)

	client.on("permission_request", function(ev)
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

		local reject_id
		for _, opt in ipairs(options) do
			if opt.kind == "reject_once" or opt.kind == "reject_always" then
				reject_id = opt.optionId
				break
			end
		end
		local allow_id
		for _, opt in ipairs(options) do
			if opt.kind == "allow_always" or opt.kind == "allow_once" then
				allow_id = opt.optionId
				break
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

	client.on("fs_read", function(ev)
		status.update("Reading: " .. vim.fn.fnamemodify(ev.text or "", ":t"))
	end)

	client.on("fs_write", function(ev)
		local path = ev.text or ""
		status.update("Writing: " .. vim.fn.fnamemodify(path, ":t"))
		-- Reload buffers that match the written file
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
end

-- ── Send queue (serialize requests on main session) ────────────────

local _send_queue = {}
local _busy = false

local function flush_send_queue()
	if #_send_queue == 0 then
		return
	end
	local next_fn = table.remove(_send_queue, 1)
	next_fn()
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

			local messages = protocol.build_prompt(regions, context_regions or {}, prompt, lsp_context, tsc_context, token)

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

		local target_mode = _planner_active and "kiro_planner" or "lg-chat"
		local return_mode = _planner_active and "kiro_planner" or "lg"

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
	end)
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
		pcall(function() acp_proc:kill(9) end)
		acp_proc = nil
	end
	vim.fn.delete(acp_sock)
end

function M.kill()
	if not main_session_id then
		return
	end
	client.cancel(main_session_id)
	main_session_id = nil
	session_models = nil
	_busy = false
	client.disconnect()
	if acp_proc then
		pcall(function() acp_proc:kill(9) end)
		acp_proc = nil
	end
end

--- @return boolean
function M.is_active()
	return main_session_id ~= nil and client.is_connected()
end

--- @return boolean
function M.is_connected()
	return acp_proc ~= nil and client.is_connected()
end

--- @return integer
function M.session_count()
	if not acp_proc or not client.is_connected() then return 0 end
	return M._session_count or 0
end

--- @return boolean
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

--- @return string?
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

-- ── Subagents (ephemeral sessions on the same lg-acp process) ──────

--- Generic subagent: creates a new session on the Go side, runs lifecycle, cleans up.
--- @param config { mode_id?: string, prompt: table, model_id?: string, label: string, on_text?: fun(text:string), on_done: fun(text:string, tool_error:string?), on_fail?: fun(), track_tool_errors?: boolean, finish_subagent?: boolean, fire_autocmds?: boolean }
local function run_subagent(config)
	status.start(config.label .. "...")
	if config.fire_autocmds ~= false then
		vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestStarted" })
	end

	ensure_acp(function(ok)
		if not ok then
			status.stop(config.label .. " failed")
			if config.on_fail then
				config.on_fail()
			else
				config.on_done("", nil)
			end
			return
		end

		local agent_text = ""
		local tool_error = nil

		-- Create a separate session for this subagent
		client.create_session(vim.fn.getcwd(), {}, function(resp)
			if resp.error then
				status.stop(config.label .. " failed")
				if config.on_fail then
					config.on_fail()
				else
					config.on_done("", nil)
				end
				return
			end

			local sub_sid = resp.session_id

			-- Set up event handlers scoped to this session
			local unsubs = {}

			unsubs[#unsubs + 1] = client.on("text", function(ev)
				if ev.session_id ~= sub_sid then
					return
				end
				agent_text = agent_text .. ev.text
				if config.on_text then
					config.on_text(ev.text)
				else
					require("lg.ui.window").append_subagent_text(ev.text)
				end
			end)

			unsubs[#unsubs + 1] = client.on("tool_call", function(ev)
				if ev.session_id ~= sub_sid then
					return
				end
				status.update(config.label .. ": " .. (ev.text or "unknown"))
			end)

			unsubs[#unsubs + 1] = client.on("tool_error", function(ev)
				if ev.session_id ~= sub_sid then
					return
				end
				if config.track_tool_errors ~= false then
					tool_error = ev.text or "unknown error"
				end
				status.flash("Tool failed: " .. (ev.text or "unknown"))
			end)

			unsubs[#unsubs + 1] = client.on("prompt_done", function(ev)
				if ev.session_id ~= sub_sid then
					return
				end
				-- Clean up
				for _, unsub in ipairs(unsubs) do
					unsub()
				end
				client.destroy_session(sub_sid)

				if tool_error then
					status.flash("Tool error: " .. tool_error)
				end
				status.stop(config.label .. " done")
				if config.finish_subagent ~= false then
					require("lg.ui.window").finish_subagent()
				end
				if config.fire_autocmds ~= false then
					vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestFinished" })
				end
				config.on_done(agent_text, tool_error)
			end)

			unsubs[#unsubs + 1] = client.on("permission_request", function(ev)
				if ev.session_id ~= sub_sid then
					return
				end
				-- Auto-approve for subagents
				local data = ev.data
				if type(data) == "string" then
					local ok2, parsed = pcall(vim.json.decode, data)
					if ok2 then
						data = parsed
					end
				end
				local options = data.options or {}
				local oid
				for _, opt in ipairs(options) do
					if opt.kind == "allow_always" or opt.kind == "allow_once" then
						oid = opt.optionId
						break
					end
				end
				if oid then
					client.respond_permission(sub_sid, data.rpc_id, oid)
				end
			end)

			-- Lifecycle: [set_model] → [set_mode] → prompt
			local function send_prompt()
				client.prompt(sub_sid, config.prompt)
			end

			local function set_mode_then_prompt()
				if config.mode_id then
					client.set_mode(sub_sid, resolve_mode(config.mode_id), function()
						send_prompt()
					end)
				else
					send_prompt()
				end
			end

			if config.model_id then
				client.set_model(sub_sid, config.model_id, function()
					set_mode_then_prompt()
				end)
			else
				set_mode_then_prompt()
			end
		end)
	end)
end

function M.send_oneshot(prompt, regions, context_regions, on_done)
	local svr = require("lg.session.server")
	local sid = svr.register_session(regions)
	local messages = protocol.build_prompt(regions, context_regions or {}, prompt)

	run_subagent({
		mode_id = "lg-oneshot",
		prompt = messages,
		label = "Quick edit",
		finish_subagent = false,
		track_tool_errors = false,
		on_done = function()
			svr.unregister_session(sid)
			if on_done then
				on_done()
			end
		end,
		on_fail = function()
			svr.unregister_session(sid)
		end,
	})
end

--- @param prompt string
--- @param on_done fun(result: string)
function M.send_git_subagent(prompt, on_done)
	local cheap_models = {
		kiro = "claude-haiku-4.5",
		opencode = "github-copilot/gpt-4.1",
	}
	local model_id = cheap_models[opts.provider] or "claude-haiku-4.5"

	run_subagent({
		prompt = { { type = "text", text = prompt } },
		model_id = model_id,
		label = "Git analysis (" .. model_id .. ")",
		on_done = function(text)
			on_done(text)
		end,
		on_fail = function()
			status.stop("Git agent failed")
			on_done("")
		end,
	})
end

function M.send_quick_chat(prompt, on_done)
	local model_id = "github-copilot/gpt-4.1"
	ephemeral_override = { provider = "opencode", model = model_id }

	run_subagent({
		prompt = { { type = "text", text = prompt } },
		model_id = model_id,
		label = "Quick chat (GPT-4.1)",
		finish_subagent = false,
		on_text = function(text)
			require("lg.ui.window").append_agent_text(text)
		end,
		on_done = function()
			ephemeral_override = nil
			if on_done then
				on_done()
			end
		end,
		on_fail = function()
			ephemeral_override = nil
			status.stop("Quick chat failed")
			if on_done then
				on_done()
			end
		end,
	})
end

-- ── Planner mode ───────────────────────────────────────────────────

function M.set_planner(enabled, callback)
	_planner_active = enabled
	connect(function(sid)
		if not sid then
			if callback then
				callback(false)
			end
			return
		end
		local mode_id = enabled and "kiro_planner" or "kiro_default"
		client.set_mode(sid, resolve_mode(mode_id))
		if callback then
			callback(true)
		end
	end)
end

function M.is_planner_active()
	return _planner_active
end

function M.kill_planner()
	_planner_active = false
end

-- ── Hint / reviewer ────────────────────────────────────────────────

function M.send_hint(prompt, regions, context_regions, on_done)
	connect(function(sid)
		if not sid then
			return
		end

		client.set_mode(sid, resolve_mode("reviewer"))

		local all_ctx = {}
		for _, r in ipairs(regions) do
			all_ctx[#all_ctx + 1] = r
		end
		for _, r in ipairs(context_regions or {}) do
			all_ctx[#all_ctx + 1] = r
		end
		local has_scope = #regions > 0
		local messages =
			protocol.build_prompt({}, all_ctx, prompt, nil, nil, nil, has_scope and { scope = "hints" } or nil)
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
	end)
end

function M.send_hint_subagent(prompt, regions, context_regions, on_done)
	local all_ctx = {}
	for _, r in ipairs(regions) do
		all_ctx[#all_ctx + 1] = r
	end
	for _, r in ipairs(context_regions or {}) do
		all_ctx[#all_ctx + 1] = r
	end
	local has_scope = #regions > 0
	local messages = protocol.build_prompt({}, all_ctx, prompt, nil, nil, nil, has_scope and { scope = "hints" } or nil)

	run_subagent({
		mode_id = "reviewer",
		prompt = messages,
		label = "Reviewing (subagent)",
		on_done = function(_, tool_error)
			if on_done then
				on_done(tool_error)
			end
		end,
	})
end

-- ── Info paint subagent ────────────────────────────────────────────

function M.send_info_subagent(prompt, regions, context_regions, on_done)
	local all_ctx = {}
	for _, r in ipairs(regions) do
		all_ctx[#all_ctx + 1] = r
	end
	for _, r in ipairs(context_regions or {}) do
		all_ctx[#all_ctx + 1] = r
	end
	local messages = protocol.build_prompt({}, all_ctx, prompt)

	run_subagent({
		mode_id = "lg-info",
		prompt = messages,
		label = "Info paint (subagent)",
		track_tool_errors = false,
		on_done = function()
			if on_done then
				on_done()
			end
		end,
	})
end

-- ── Suggest ────────────────────────────────────────────────────────

function M.send_suggest(prompt, regions, context_regions, on_done)
	connect(function(sid)
		if not sid then
			return
		end

		client.set_mode(sid, resolve_mode("suggester"))

		local all_ctx = {}
		for _, r in ipairs(regions) do
			all_ctx[#all_ctx + 1] = r
		end
		for _, r in ipairs(context_regions or {}) do
			all_ctx[#all_ctx + 1] = r
		end
		local has_scope = #regions > 0
		local messages =
			protocol.build_prompt({}, all_ctx, prompt, nil, nil, nil, has_scope and { scope = "suggestions" } or nil)
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
	end)
end

function M.send_suggest_subagent(prompt, regions, context_regions, on_done)
	local all_ctx = {}
	for _, r in ipairs(regions) do
		all_ctx[#all_ctx + 1] = r
	end
	for _, r in ipairs(context_regions or {}) do
		all_ctx[#all_ctx + 1] = r
	end
	local has_scope = #regions > 0
	local messages =
		protocol.build_prompt({}, all_ctx, prompt, nil, nil, nil, has_scope and { scope = "suggestions" } or nil)

	run_subagent({
		mode_id = "suggester",
		prompt = messages,
		label = "Suggesting (subagent)",
		on_done = function(_, tool_error)
			if on_done then
				on_done(tool_error)
			end
		end,
	})
end

-- ── Help (info paint + suggestions) ────────────────────────────────

function M.send_help(prompt, regions, context_regions, on_done)
	connect(function(sid)
		if not sid then
			return
		end

		client.set_mode(sid, resolve_mode("helper"))

		local all_ctx = {}
		for _, r in ipairs(regions) do
			all_ctx[#all_ctx + 1] = r
		end
		for _, r in ipairs(context_regions or {}) do
			all_ctx[#all_ctx + 1] = r
		end
		local has_scope = #regions > 0
		local messages =
			protocol.build_prompt({}, all_ctx, prompt, nil, nil, nil, has_scope and { scope = "help" } or nil)
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
	end)
end

function M.send_help_subagent(prompt, regions, context_regions, on_done)
	local all_ctx = {}
	for _, r in ipairs(regions) do
		all_ctx[#all_ctx + 1] = r
	end
	for _, r in ipairs(context_regions or {}) do
		all_ctx[#all_ctx + 1] = r
	end
	local has_scope = #regions > 0
	local messages =
		protocol.build_prompt({}, all_ctx, prompt, nil, nil, nil, has_scope and { scope = "help" } or nil)

	run_subagent({
		mode_id = "helper",
		prompt = messages,
		label = "Help (subagent)",
		on_done = function(_, tool_error)
			if on_done then
				on_done(tool_error)
			end
		end,
	})
end

-- ── Session restore ────────────────────────────────────────────────

--- Read kiro session files from disk and return sorted list (kiro-only, has previews).
--- @param cwd string filter by cwd
--- @return table[] sessions { id, cwd, date, title, preview }
local function read_kiro_sessions(cwd)
	local dir = vim.fn.expand("~/.kiro/sessions/cli")
	local files = vim.fn.glob(dir .. "/*.json", false, true)
	local sessions = {}
	for _, path in ipairs(files) do
		local f = io.open(path, "r")
		if f then
			local ok, data = pcall(vim.json.decode, f:read("*a"))
			f:close()
			if ok and data.cwd == cwd then
				local state = data.session_state or {}
				local meta = state.conversation_metadata or {}
				local turns = meta.user_turn_metadatas or {}

				-- Extract first assistant text as title + build preview
				local title
				local preview_lines = {}
				for _, turn in ipairs(turns) do
					if turn.result and turn.result.Ok then
						local content = turn.result.Ok.content or {}
						for _, c in ipairs(content) do
							if c.kind == "text" and c.data and #c.data > 0 then
								local text = c.data:gsub("^%s+", "")
								if not title then
									title = text:sub(1, 80)
								end
								for _, line in ipairs(vim.split(text, "\n")) do
									preview_lines[#preview_lines + 1] = line
									if #preview_lines >= 40 then break end
								end
							end
						end
					end
					if #preview_lines >= 40 then break end
				end

				table.insert(sessions, {
					id = data.session_id,
					cwd = data.cwd,
					date = (data.updated_at or ""):sub(1, 16):gsub("T", " "),
					title = title or "(untitled)",
					preview = table.concat(preview_lines, "\n"),
				})
			end
		end
	end
	table.sort(sessions, function(a, b) return a.date > b.date end)
	return sessions
end

--- List sessions via ACP session/list (works for any provider).
--- @param on_done fun(sessions: table[])
--- List sessions via the Go binary (handles provider differences internally).
--- @param on_done fun(sessions: table[])
local function list_sessions_acp(on_done)
	ensure_acp(function(ok)
		if not ok then
			on_done({})
			return
		end
		client.list_sessions(vim.fn.getcwd(), function(resp)
			if resp.error or not resp.data then
				on_done({})
				return
			end
			local ok2, data = pcall(vim.json.decode, type(resp.data) == "string" and resp.data or vim.json.encode(resp.data))
			if not ok2 then
				on_done({})
				return
			end
			local sessions = {}
			-- Opencode: array of {id, title, date, preview}
			-- Kiro ACP: {sessions: [{sessionId, title, updatedAt, cwd}]}
			local list = data.sessions or data
			if type(list) ~= "table" then
				on_done({})
				return
			end
			for _, s in ipairs(list) do
				local title = s.title or ""
				if not title:match("^ACP Session ") and not title:match("^New session %- ") then
					table.insert(sessions, {
						id = s.sessionId or s.id,
						cwd = s.cwd or "",
						date = s.date or (s.updatedAt or ""):sub(1, 16):gsub("T", " "),
						title = title ~= "" and title or "(untitled)",
						preview = s.preview or "",
					})
				end
			end
			table.sort(sessions, function(a, b) return a.date > b.date end)
			on_done(sessions)
		end)
	end)
end

function M.restore_session()
	local function show_picker(sessions)
		if #sessions == 0 then
			vim.notify("lg: no previous sessions for this project", vim.log.levels.INFO)
			return
		end

		local entries = {}
		local has_preview = false
		local preview_dir = "/dev/shm/lg-session-preview"
		vim.fn.delete(preview_dir, "rf")
		vim.fn.mkdir(preview_dir, "p")
		for i, s in ipairs(sessions) do
			if s.preview ~= "" then has_preview = true end
			local pf = io.open(preview_dir .. "/" .. s.id, "w")
			if pf then
				pf:write(s.preview ~= "" and s.preview or s.title)
				pf:close()
			end
			entries[i] = s.id .. "\t" .. string.format("\x1b[36m%s\x1b[0m  \x1b[33m%s\x1b[0m", s.date, s.title)
		end

		local fzf_opts = {
			["--ansi"] = "",
			["--delimiter"] = "\t",
			["--with-nth"] = "2..",
		}
		if has_preview then
			fzf_opts["--preview"] = "CLICOLOR_FORCE=1 glow -s dark " .. preview_dir .. "/{1}"
			fzf_opts["--preview-window"] = "right:50%:wrap"
		else
			fzf_opts["--preview-window"] = "hidden"
		end

		require("fzf-lua").fzf_exec(entries, {
			prompt = "  ",
			fzf_opts = fzf_opts,
			winopts = {
				title = " 󰋚 Restore Session ",
				title_pos = "center",
				height = 0.6,
				width = has_preview and 0.75 or 0.6,
			},
			actions = {
				["default"] = function(selected)
					vim.fn.delete(preview_dir, "rf")
					if not selected or #selected == 0 then return end
					local sid = selected[1]:match("^([^\t]+)")
					if sid then
						M._do_load_session(sid)
					end
				end,
				["ctrl-x"] = function(selected)
					if not selected or #selected == 0 then return end
					for _, item in ipairs(selected) do
						local sid = item:match("^([^\t]+)")
						if sid then
							client.delete_session(sid, function() end)
							vim.notify("lg: deleted session " .. sid:sub(1, 8), vim.log.levels.INFO)
						end
					end
					vim.fn.delete(preview_dir, "rf")
					M.restore_session()
				end,
			},
		})
	end

	list_sessions_acp(function(sessions)
		vim.schedule(function() show_picker(sessions) end)
	end)
end

function M._do_load_session(session_id)
	if main_session_id then
		client.destroy_session(main_session_id)
		main_session_id = nil
	end

	status.start("Restoring session...")
	M._restoring = true

	ensure_acp(function(ok)
		if not ok then
			status.stop("Connection failed")
			return
		end

		M._setup_event_handlers()

		-- Listen for session_loaded to know replay is done
		local unsub
		unsub = client.on("session_loaded", function(ev)
			if ev.session_id ~= session_id then return end
			if unsub then unsub() end
			M._restoring = false
			client.set_mode(session_id, resolve_mode("lg"))
			-- Fetch models so select_model works
			client.get_models(function(resp)
				if resp.models then
					session_models = resp.models
				end
			end)
			status.stop("Session restored")
		end)

		client.load_session(session_id, vim.fn.getcwd(), function(resp)
			if resp.error then
				if unsub then unsub() end
				M._restoring = false
				status.stop("Restore failed: " .. resp.error)
				return
			end
			main_session_id = resp.session_id
			refresh_session_count()
		end)
	end)
end

return M
