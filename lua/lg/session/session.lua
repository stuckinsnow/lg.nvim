--- Session: thin orchestrator for ACP sessions
---
--- Manages: shared process lifecycle, main session, subagent dispatch.
--- Delegates to: process.lua (transport), handlers.lua (message handling),
--- subagent.lua (ephemeral sessions), protocol.lua (message building).

local Process = require("lg.session.process")
local protocol = require("lg.session.protocol")
local handlers = require("lg.session.handlers")
local subagent = require("lg.session.subagent")
local status = require("lg.status")

local M = {}

local _planner_active = false

--- @type lg.Process?
local shared_process = nil
--- @type lg.ProcessSession?
local main_session = nil
local opts = {}

local providers = {
	kiro = { cmd = { "kiro-cli", "acp" }, name = "Kiro" },
	opencode = { cmd = { "opencode", "acp" }, name = "OpenCode" },
}

local state_path = "/dev/shm/lg-state.json"

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
		cmd = { "kiro-cli", "acp" },
		timeout = 30000,
		mcp_servers = {},
		provider = "kiro",
	}, user_opts or {})

	local saved = load_state()
	if saved.provider and providers[saved.provider] then
		opts.provider = saved.provider
	end

	if providers[opts.provider] then
		opts.cmd = providers[opts.provider].cmd
	end
end

-- ── Shared process + main session ──────────────────────────────────

local _connect_queue = nil

--- Ensure shared process is running and main session exists.
--- Queues concurrent callers — only one spawn at a time.
--- @param on_ready fun(session: lg.ProcessSession?)
local function connect(on_ready)
	if main_session and shared_process and shared_process:is_healthy() then
		on_ready(main_session)
		return
	end

	if _connect_queue then
		table.insert(_connect_queue, on_ready)
		return
	end
	_connect_queue = { on_ready }

	local function flush(s)
		local q = _connect_queue
		_connect_queue = nil
		for _, cb in ipairs(q) do
			cb(s)
		end
	end

	status.start("Connecting...")

	Process.spawn({ cmd = opts.cmd, client_name = "lg" }, function(proc)
		if not proc then
			status.stop("Connection failed")
			flush(nil)
			return
		end
		shared_process = proc

		proc:create_session(handlers.handle_main, opts.mcp_servers, function(session)
			if not session then
				status.stop("Session failed")
				proc:terminate()
				shared_process = nil
				flush(nil)
				return
			end
			main_session = session

			-- Restore persisted model
			local saved = load_state()
			if saved.model and session.models then
				for _, m in ipairs(session.models.availableModels or {}) do
					if m.modelId == saved.model then
						local id = session:next_rpc_id()
						session:write({
							jsonrpc = "2.0",
							id = id,
							method = "session/set_model",
							params = { sessionId = session.session_id, modelId = saved.model },
						})
						session.models.currentModelId = saved.model
						break
					end
				end
			end

			-- Switch to lg agent mode
			local mid = session:next_rpc_id()
			session:write({
				jsonrpc = "2.0",
				id = mid,
				method = "session/set_mode",
				params = { sessionId = session.session_id, modeId = "lg" },
			})

			status.stop("Session ready")

			vim.api.nvim_create_autocmd("VimLeavePre", {
				group = vim.api.nvim_create_augroup("lg.session.session", { clear = true }),
				callback = function()
					M.clear()
				end,
			})

			flush(session)
		end)
	end)
end

--- Get or create the shared process, then call on_ready.
--- For subagents that need the shared process but not the main session.
--- @param on_ready fun(process: lg.Process?)
local function ensure_process(on_ready)
	if shared_process and shared_process:is_healthy() then
		on_ready(shared_process)
		return
	end
	-- Connect creates both process + main session; subagents piggyback
	connect(function(session)
		if session then
			on_ready(shared_process)
		else
			on_ready(nil)
		end
	end)
end

-- ── Public API: main session ───────────────────────────────────────

local _send_queue = {}

local function flush_send_queue(s)
	if #_send_queue == 0 then return end
	local next_req = table.remove(_send_queue, 1)
	next_req(s)
end

function M.send(prompt, regions, context_regions, on_done, lsp_context, tsc_context)
	connect(function(s)
		if not s then return end

		local function do_send(session)
			session._prompt_count = (session._prompt_count or 0) + 1
			local token = nil
			if #regions > 0 then
				local svr = require("lg.session.server")
				token = svr.create_token(regions)
			end

			local messages = protocol.build_prompt(regions, context_regions or {}, prompt, lsp_context, tsc_context, token)

			status.start("Thinking...")
			vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestStarted" })

			local id = session:next_rpc_id()
			if not session._on_done then session._on_done = {} end
			session._on_done[id] = function()
				if on_done then on_done() end
				flush_send_queue(session)
			end

			session:track_response(id)
			session:write({
				jsonrpc = "2.0",
				id = id,
				method = "session/prompt",
				params = { sessionId = session.session_id, prompt = messages },
			})
		end

		if M.is_busy() then
			table.insert(_send_queue, do_send)
			status.update("Queued (waiting for current request)...")
		else
			do_send(s)
		end
	end)
end

function M.send_chat(prompt, on_done)
	connect(function(s)
		if not s then return end

		local target_mode = _planner_active and "planner" or "lg-chat"
		local return_mode = _planner_active and "planner" or "lg"

		-- Switch to appropriate mode (only show message if actually switching)
		if not _planner_active then
			require("lg.ui.window").add_status("Switching to chat mode")
		end
		local mid = s:next_rpc_id()
		s:write({
			jsonrpc = "2.0",
			id = mid,
			method = "session/set_mode",
			params = { sessionId = s.session_id, modeId = target_mode },
		})

		local messages = protocol.build_prompt({}, {}, prompt)

		status.start("Thinking...")
		vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestStarted" })

		local id = s:next_rpc_id()
		if not s._on_done then s._on_done = {} end
		s._on_done[id] = function()
			-- Switch back to original mode
			if not _planner_active then
				require("lg.ui.window").add_status("Switching to paint mode")
			end
			local rid = s:next_rpc_id()
			s:write({
				jsonrpc = "2.0",
				id = rid,
				method = "session/set_mode",
				params = { sessionId = s.session_id, modeId = return_mode },
			})
			if on_done then on_done() end
			flush_send_queue(s)
		end

		s:track_response(id)
		s:write({
			jsonrpc = "2.0",
			id = id,
			method = "session/prompt",
			params = { sessionId = s.session_id, prompt = messages },
		})
	end)
end

function M.clear()
	_connect_queue = nil
	_send_queue = {}
	require("lg.session.server").clear_tokens()
	main_session = nil
	if shared_process then
		shared_process:terminate()
		shared_process = nil
	end
end

function M.kill()
	if not main_session then
		return
	end
	main_session.killed = true
	main_session = nil
	if shared_process then
		shared_process:terminate()
		shared_process = nil
	end
end

--- @return boolean
function M.is_active()
	return main_session ~= nil and shared_process ~= nil and shared_process:is_healthy()
end

--- @return boolean
function M.is_busy()
	return main_session ~= nil and main_session._on_done ~= nil and next(main_session._on_done) ~= nil
end

function M.select_model()
	connect(function(s)
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
				local id = s:next_rpc_id()
				s:write({
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
	end)
end

local ephemeral_override = nil

--- @return string?
function M.current_model()
	if ephemeral_override then
		return ephemeral_override.model
	end
	if main_session and main_session.models then
		return main_session.models.currentModelId
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
			if picked == opts.provider and main_session then
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

function M.info()
	local lines = {}
	local function add(s)
		lines[#lines + 1] = s
	end

	add("Provider: " .. (providers[opts.provider] and providers[opts.provider].name or opts.provider))
	add("Model: " .. (M.current_model() or "default"))
	add("Session: " .. (main_session and main_session.session_id and "active" or "none"))
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

-- ── Subagents (ephemeral sessions on shared process) ───────────────

local oneshot_active = false

function M.send_oneshot(prompt, regions, context_regions, on_done)
	if oneshot_active then
		vim.notify("Oneshot already running", vim.log.levels.WARN)
		return
	end
	oneshot_active = true
	local svr = require("lg.session.server")
	local sid = svr.register_session(regions)
	local messages = protocol.build_prompt(regions, context_regions or {}, prompt)

	ensure_process(function(proc)
		if not proc then
			oneshot_active = false
			svr.unregister_session(sid)
			return
		end
		subagent.run(proc, {
			mode_id = "lg-oneshot",
			prompt = messages,
			label = "Quick edit",
			finish_subagent = false,
			track_tool_errors = false,
			on_done = function()
				oneshot_active = false
				svr.unregister_session(sid)
				if on_done then
					on_done()
				end
			end,
			on_fail = function()
				oneshot_active = false
				svr.unregister_session(sid)
			end,
		})
	end)
end

--- @param prompt string
--- @param on_done fun(result: string)
function M.send_git_subagent(prompt, on_done)
	local cheap_models = {
		kiro = "claude-haiku-4.5",
		opencode = "github-copilot/gpt-4.1",
	}
	local model_id = cheap_models[opts.provider] or "claude-haiku-4.5"

	ensure_process(function(proc)
		if not proc then
			status.stop("Git agent failed")
			on_done("")
			return
		end
		subagent.run(proc, {
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
	end)
end

function M.send_quick_chat(prompt, on_done)
	local model_id = "github-copilot/gpt-4.1"
	ephemeral_override = { provider = "opencode", model = model_id }

	-- Quick chat uses opencode — needs its own process
	Process.spawn({ cmd = { "opencode", "acp" }, client_name = "lg-quick-chat" }, function(proc)
		if not proc then
			ephemeral_override = nil
			status.stop("Quick chat failed")
			if on_done then
				on_done()
			end
			return
		end
		subagent.run(proc, {
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
				vim.defer_fn(function()
					proc:terminate()
				end, 500)
			end,
			on_fail = function()
				ephemeral_override = nil
				status.stop("Quick chat failed")
				if on_done then
					on_done()
				end
				proc:terminate()
			end,
		})
	end)
end

-- ── Planner mode (set_mode on main session) ───────────────────────

function M.set_planner(enabled, callback)
	_planner_active = enabled
	connect(function(s)
		if not s then
			if callback then
				callback(false)
			end
			return
		end
		local mode_id = enabled and "planner" or "kiro_default"
		local id = s:next_rpc_id()
		s:write({
			jsonrpc = "2.0",
			id = id,
			method = "session/set_mode",
			params = { sessionId = s.session_id, modeId = mode_id },
		})
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

-- ── Hint / reviewer (main session variant) ────────────────────────

function M.send_hint(prompt, regions, context_regions, on_done)
	connect(function(s)
		if not s then
			return
		end

		local id = s:next_rpc_id()
		s:write({
			jsonrpc = "2.0",
			id = id,
			method = "session/set_mode",
			params = { sessionId = s.session_id, modeId = "reviewer" },
		})

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

		local pid = s:next_rpc_id()
		if not s._on_done then s._on_done = {} end
		s._on_done[pid] = function()
			local rid = s:next_rpc_id()
			s:write({
				jsonrpc = "2.0",
				id = rid,
				method = "session/set_mode",
				params = { sessionId = s.session_id, modeId = "lg" },
			})
			if on_done then
				on_done()
			end
			flush_send_queue(s)
		end

		s:track_response(pid)
		s:write({
			jsonrpc = "2.0",
			id = pid,
			method = "session/prompt",
			params = { sessionId = s.session_id, prompt = messages },
		})
	end)
end

-- ── Hint subagent (ephemeral session on shared process) ───────────

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

	ensure_process(function(proc)
		if not proc then
			if on_done then
				on_done()
			end
			return
		end
		subagent.run(proc, {
			mode_id = "reviewer",
			prompt = messages,
			label = "Reviewing (subagent)",
			on_done = function(_, tool_error)
				if on_done then
					on_done(tool_error)
				end
			end,
		})
	end)
end

-- ── Info paint subagent ───────────────────────────────────────────

function M.send_info_subagent(prompt, regions, context_regions, on_done)
	local all_ctx = {}
	for _, r in ipairs(regions) do
		all_ctx[#all_ctx + 1] = r
	end
	for _, r in ipairs(context_regions or {}) do
		all_ctx[#all_ctx + 1] = r
	end
	local messages = protocol.build_prompt({}, all_ctx, prompt)

	ensure_process(function(proc)
		if not proc then
			if on_done then
				on_done()
			end
			return
		end
		subagent.run(proc, {
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
	end)
end

-- ── Suggest (main session variant) ────────────────────────────────

function M.send_suggest(prompt, regions, context_regions, on_done)
	connect(function(s)
		if not s then
			return
		end

		local id = s:next_rpc_id()
		s:write({
			jsonrpc = "2.0",
			id = id,
			method = "session/set_mode",
			params = { sessionId = s.session_id, modeId = "suggester" },
		})

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

		local pid = s:next_rpc_id()
		if not s._on_done then s._on_done = {} end
		s._on_done[pid] = function()
			local rid = s:next_rpc_id()
			s:write({
				jsonrpc = "2.0",
				id = rid,
				method = "session/set_mode",
				params = { sessionId = s.session_id, modeId = "lg" },
			})
			if on_done then
				on_done()
			end
			flush_send_queue(s)
		end

		s:track_response(pid)
		s:write({
			jsonrpc = "2.0",
			id = pid,
			method = "session/prompt",
			params = { sessionId = s.session_id, prompt = messages },
		})
	end)
end

-- ── Suggest subagent ──────────────────────────────────────────────

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

	ensure_process(function(proc)
		if not proc then
			if on_done then
				on_done()
			end
			return
		end
		subagent.run(proc, {
			mode_id = "suggester",
			prompt = messages,
			label = "Suggesting (subagent)",
			on_done = function(_, tool_error)
				if on_done then
					on_done(tool_error)
				end
			end,
		})
	end)
end

return M
