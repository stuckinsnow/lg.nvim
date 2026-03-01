--- Session: manages a persistent kiro-cli ACP subprocess
--- Handles: spawn, initialize, session/new, session/prompt lifecycle.

local protocol = require("lg.session.protocol")
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

--- Default message handler for main + oneshot sessions.
--- @param s table
--- @param msg table
local function handle_message(s, msg)
	if s.killed then return end
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
						require("lg.ui.window").append_agent_text(content.text)
					end)
				end
			elseif update.sessionUpdate == "tool_call" then
				vim.schedule(function()
					local title = update.title or update.toolCallId or "unknown"
					status.update("Tool: " .. title)
					require("lg.ui.window").add_tool(title)
					vim.api.nvim_exec_autocmds("User", { pattern = "LgToolCall", data = { title = title } })
					if update.kind == "edit" and update.content and update.toolCallId then
						if not s._seen_tool_calls then s._seen_tool_calls = {} end
						if not s._seen_tool_calls[update.toolCallId] then
							s._seen_tool_calls[update.toolCallId] = true
							local hunk = require("lg.ui.hunk")
							local any = false
							local loc_path = update.locations and update.locations[1] and update.locations[1].path
							for _, c in ipairs(update.content) do
								local p = c.path or loc_path
								local old = c.oldText
								local new = c.newText
								if p and old and new and (c.type == "diff" or old ~= new) then
									if hunk.propose_edit(p, old, new) then any = true end
								end
							end
							if not any then s._seen_tool_calls[update.toolCallId] = "failed" end
						end
					end
				end)
			elseif update.sessionUpdate == "tool_call_update" and update.status == "completed"
				and update.kind == "edit" and update.content and update.toolCallId then
				vim.schedule(function()
					if not s._seen_tool_calls then s._seen_tool_calls = {} end
					if not s._seen_tool_calls[update.toolCallId] then
						s._seen_tool_calls[update.toolCallId] = true
						local hunk = require("lg.ui.hunk")
						local loc_path = update.locations and update.locations[1] and update.locations[1].path
						for _, c in ipairs(update.content) do
							if c.type == "diff" and c.path and c.oldText and c.newText then
								hunk.propose_edit(c.path, c.oldText, c.newText)
							end
						end
					end
				end)
			elseif update.sessionUpdate == "tool_call_update" and update.status == "error" then
				vim.schedule(function()
					status.flash("Tool failed: " .. (update.message or update.title or "unknown"))
				end)
			end
		end
	elseif method == "session/request_permission" then
		local tool_options = msg.params and msg.params.options or {}
		local tc = msg.params and msg.params.toolCall
		local title = tc and tc.title or ""
		local option_id
		for _, opt in ipairs(tool_options) do
			if opt.kind == "allow_always" or opt.kind == "allow_once" then
				option_id = opt.optionId
				break
			end
		end
		option_id = option_id or (tool_options[1] and tool_options[1].optionId)
		if option_id and msg.id then
			if title:match("^Editing ") then
				local tcid = tc and tc.toolCallId
				local failed = tcid and s._seen_tool_calls and s._seen_tool_calls[tcid] == "failed"
				if failed then
					-- propose_edit couldn't find old_text — auto-approve so CLI isn't stuck
					vim.schedule(function() status.update("Auto-approved: " .. title) end)
					write(s, {
						jsonrpc = "2.0", id = msg.id,
						result = { outcome = { outcome = "selected", optionId = option_id } },
					})
				else
					vim.schedule(function()
						status.update("Review: " .. title)
						local fname = title:match("^Editing (.+)$")
						local bufnr
						if fname then
							for _, buf in ipairs(vim.api.nvim_list_bufs()) do
								if vim.api.nvim_buf_is_loaded(buf) and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t") == fname then
									bufnr = buf; break
								end
							end
						end
						require("lg.ui.hunk").hold_permission(s, msg.id, option_id, write, bufnr)
					end)
				end
			elseif title:match("^Creating ") or title:match("^Deleting ")
				or (title:match("^Running") and title:match("[:%s]rm ")) then
				local reject_id
				for _, opt in ipairs(tool_options) do
					if opt.kind == "reject_once" or opt.kind == "reject_always" then
						reject_id = opt.optionId; break
					end
				end
				vim.schedule(function()
					vim.ui.select({ "Allow", "Reject" }, { prompt = title .. "?" }, function(choice)
						local oid = choice == "Allow" and option_id or reject_id or option_id
						write(s, {
							jsonrpc = "2.0", id = msg.id,
							result = { outcome = { outcome = "selected", optionId = oid } },
						})
						status.update(choice == "Allow" and ("Approved: " .. title) or ("Rejected: " .. title))
					end)
				end)
			else
				vim.schedule(function()
					status.update("Approved: " .. title)
				end)
				write(s, {
					jsonrpc = "2.0", id = msg.id,
					result = { outcome = { outcome = "selected", optionId = option_id } },
				})
			end
		end
	elseif method == "fs/read_text_file" then
		local path = msg.params and msg.params.path
		if path and msg.id then
			vim.schedule(function() status.update("Reading: " .. vim.fn.fnamemodify(path, ":t")) end)
			local content = ""
			local f = io.open(path, "r")
			if f then content = f:read("*a"); f:close() end
			write(s, { jsonrpc = "2.0", id = msg.id, result = { content = content } })
		end
	elseif method == "fs/write_text_file" then
		local path = msg.params and msg.params.path
		local content = msg.params and msg.params.content or ""
		if path and msg.id then
			local resolved = vim.fn.fnamemodify(path, ":p")
			vim.schedule(function() status.update("Writing: " .. vim.fn.fnamemodify(path, ":t")) end)
			local f = io.open(resolved, "w")
			if f then f:write(content); f:close() end
			write(s, { jsonrpc = "2.0", id = msg.id, result = vim.NIL })
			vim.schedule(function()
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
		end
	end
end

--- Spawn an ACP process, run init + session/new handshake, call on_ready(s).
--- Fully async — never blocks the editor.
--- @param spawn_opts { cmd: string[], mcp_servers: table, client_name: string, on_message?: fun(s:table, msg:table), on_fail?: fun() }
--- @param on_ready fun(s: table?)
local function spawn_session(spawn_opts, on_ready)
	local msg_handler = spawn_opts.on_message or handle_message

	local s = {
		proc = nil,
		next_id = 1,
		pending = {},
		session_id = nil,
		stdout_buf = "",
		models = nil,
	}

	-- stdout line parser → JSON → handler
	local function process_stdout(data)
		s.stdout_buf = s.stdout_buf .. data
		while true do
			local nl = s.stdout_buf:find("\n")
			if not nl then break end
			local line = s.stdout_buf:sub(1, nl - 1):gsub("\r$", "")
			s.stdout_buf = s.stdout_buf:sub(nl + 1)
			if line ~= "" and line:match("^%s*{") then
				local ok, msg = pcall(vim.json.decode, line)
				if ok then
					-- During handshake, intercept responses
					if s._handshake then
						s._handshake(msg)
					else
						msg_handler(s, msg)
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
			stdout = vim.schedule_wrap(function(_, data) if data then process_stdout(data) end end),
			stderr = vim.schedule_wrap(function(_, _) end),
		},
		vim.schedule_wrap(function(_)
			s.proc = nil
			s.session_id = nil
		end)
	)
	s.proc = proc

	-- Async handshake: init → session → ready
	local phase = "init"
	s._handshake = function(msg)
		if not (msg.id and not msg.method) then
			msg_handler(s, msg)
			return
		end

		local result = msg.result
		local err = msg.error

		if phase == "init" then
			if err or not result then
				s._handshake = nil
				if spawn_opts.on_fail then spawn_opts.on_fail() end
				on_ready(nil)
				return
			end
			phase = "session"
			local id = s.next_id; s.next_id = id + 1
			write(s, {
				jsonrpc = "2.0", id = id, method = "session/new",
				params = { cwd = vim.fn.getcwd(), mcpServers = spawn_opts.mcp_servers or {} },
			})

		elseif phase == "session" then
			s._handshake = nil
			if err or not result or not result.sessionId then
				if spawn_opts.on_fail then spawn_opts.on_fail() end
				on_ready(nil)
				return
			end
			s.session_id = result.sessionId
			s.models = result.models
			if s.models and not s.models.currentModelId then
				local avail = s.models.availableModels
				if avail and avail[1] then s.models.currentModelId = avail[1].modelId end
			end
			on_ready(s)
		end
	end

	-- Kick off: send initialize
	local id = s.next_id; s.next_id = id + 1
	write(s, {
		jsonrpc = "2.0", id = id, method = "initialize",
		params = {
			protocolVersion = 1,
			clientCapabilities = { fs = { readTextFile = true, writeTextFile = false } },
			clientInfo = { name = spawn_opts.client_name or "lg", version = "2.0.0" },
		},
	})

	return s
end

-- ── Main session (persistent) ──────────────────────────────────────

local _connect_queue = nil

local function connect(on_ready)
	if state and state.proc then
		on_ready(state)
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
		for _, cb in ipairs(q) do cb(s) end
	end

	status.start("Connecting...")

	state = spawn_session({
		cmd = opts.cmd,
		mcp_servers = opts.mcp_servers,
		client_name = "lg",
		on_fail = function()
			status.stop("Connection failed")
			state = nil
		end,
	}, function(s)
		if not s then
			flush(nil)
			return
		end

		-- Restore persisted model
		local saved = load_state()
		if saved.model and s.models then
			for _, m in ipairs(s.models.availableModels or {}) do
				if m.modelId == saved.model then
					local id = s.next_id; s.next_id = id + 1
					write(s, {
						jsonrpc = "2.0", id = id, method = "session/set_model",
						params = { sessionId = s.session_id, modelId = saved.model },
					})
					s.models.currentModelId = saved.model
					break
				end
			end
		end

		-- Switch to lg agent mode (scoped MCP servers)
		local mid = s.next_id; s.next_id = mid + 1
		write(s, {
			jsonrpc = "2.0", id = mid, method = "session/set_mode",
			params = { sessionId = s.session_id, modeId = "lg" },
		})

		status.stop("Session ready")

		vim.api.nvim_create_autocmd("VimLeavePre", {
			group = vim.api.nvim_create_augroup("lg.session.session", { clear = true }),
			callback = function() M.clear() end,
		})

		flush(s)
	end)
end

function M.send(prompt, regions, context_regions, on_done, lsp_context, tsc_context)
	connect(function(s)
		if not s then return end

		s._prompt_count = (s._prompt_count or 0) + 1
		local token = nil
		if #regions > 0 then
			local svr = require("lg.session.server")
			token = svr.create_token(regions)
		end

		local messages = protocol.build_prompt(regions, context_regions or {}, prompt, lsp_context, tsc_context, token)

		status.start("Thinking...")
		vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestStarted" })

		s._on_done = on_done

		local id = s.next_id
		s.next_id = id + 1
		write(s, {
			jsonrpc = "2.0", id = id, method = "session/prompt",
			params = { sessionId = s.session_id, prompt = messages },
		})
	end)
end

function M.clear()
	_connect_queue = nil
	require("lg.session.server").clear_tokens()
	if not state then return end
	if state.proc then
		pcall(function() state.proc:kill(9) end)
	end
	state = nil
end

function M.kill()
	if not state then return end
	state.killed = true
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
				if not choice then return end
				local model_id = choice:gsub(" %(current%)$", "")
				local id = s.next_id
				s.next_id = id + 1
				write(s, {
					jsonrpc = "2.0", id = id, method = "session/set_model",
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
	if ephemeral_override then return ephemeral_override.model end
	if state and state.models then
		return state.models.currentModelId
	end
	local saved = load_state()
	return saved.model
end

function M.current_provider()
	if ephemeral_override then return ephemeral_override.provider end
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
	table.sort(names, function(a, b) return a.label < b.label end)

	local labels = vim.tbl_map(function(n) return n.label end, names)

	vim.ui.select(
		labels,
		{ prompt = "lg provider (current: " .. (providers[opts.provider].name or "?") .. "):" },
		function(choice, idx)
			if not choice or not idx then return end
			local picked = names[idx].key
			if picked == opts.provider and state then return end
			opts.provider = picked
			opts.cmd = providers[picked].cmd
			M.clear()
			save_state({ provider = picked, model = M.current_model() })
			vim.notify("lg: provider → " .. providers[picked].name, vim.log.levels.INFO)
			vim.schedule(function() M.select_model() end)
		end
	)
end

function M.info()
	local lines = {}
	local function add(s) lines[#lines + 1] = s end

	-- Provider & model
	add("Provider: " .. (providers[opts.provider] and providers[opts.provider].name or opts.provider))
	add("Model: " .. (M.current_model() or "default"))
	add("Session: " .. (state and state.session_id and "active" or "none"))
	add("")

	-- Read agent configs from ~/.kiro/agents/
	local agents_dir = vim.fn.expand("~/.kiro/agents")
	local agent_files = vim.fn.glob(agents_dir .. "/*.json", false, true)
	for _, path in ipairs(agent_files) do
		local f = io.open(path, "r")
		if f then
			local ok, cfg = pcall(vim.json.decode, f:read("*a"))
			f:close()
			if ok and cfg.name then
				local mcps = {}
				for name, _ in pairs(cfg.mcpServers or {}) do mcps[#mcps + 1] = name end
				add(string.format("Agent [%s]: model=%s  mcps=%s  tools=%s",
					cfg.name,
					cfg.model or "default",
					#mcps > 0 and table.concat(mcps, ",") or "none",
					cfg.tools and table.concat(cfg.tools, ",") or "none"
				))
			end
		end
	end

	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

-- ── Oneshot session (ephemeral) ────────────────────────────────────

local oneshot_active = false

function M.send_oneshot(prompt, regions, context_regions, on_done)
	if oneshot_active then
		vim.notify("Oneshot already running", vim.log.levels.WARN)
		return
	end
	oneshot_active = true
	local svr = require("lg.session.server")
	local sid = svr.register_session(regions)

	local function silent_handler(s, msg)
		if msg.id and not msg.method then
			if msg.result and msg.result.stopReason then
				vim.schedule(function()
					status.stop("Quick edit done")
					vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestFinished" })
					if s._on_done then s._on_done(); s._on_done = nil end
				end)
			end
			return
		end
		local method = msg.method or ""
		if method == "session/request_permission" then
			local tool_options = msg.params and msg.params.options or {}
			local option_id
			for _, opt in ipairs(tool_options) do
				if opt.kind == "allow_always" or opt.kind == "allow_once" then
					option_id = opt.optionId; break
				end
			end
			option_id = option_id or (tool_options[1] and tool_options[1].optionId)
			if option_id and msg.id then
				write(s, { jsonrpc = "2.0", id = msg.id, result = { outcome = { outcome = "selected", optionId = option_id } } })
			end
		end
	end

	spawn_session({
		cmd = opts.cmd,
		mcp_servers = {},
		client_name = "lg-quick",
		on_message = silent_handler,
	}, function(sess)
		if not sess then oneshot_active = false; svr.unregister_session(sid); return end

		local mid = sess.next_id; sess.next_id = mid + 1
		write(sess, {
			jsonrpc = "2.0", id = mid, method = "session/set_mode",
			params = { sessionId = sess.session_id, modeId = "lg-oneshot" },
		})

		sess._on_done = function()
			oneshot_active = false
			svr.unregister_session(sid)
			if on_done then on_done() end
			vim.defer_fn(function() pcall(function() sess.proc:kill(9) end) end, 500)
		end

		local messages = protocol.build_prompt(regions, context_regions or {}, prompt)
		status.start("Quick edit...")
		vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestStarted" })
		local id = sess.next_id; sess.next_id = id + 1
		write(sess, {
			jsonrpc = "2.0", id = id, method = "session/prompt",
			params = { sessionId = sess.session_id, prompt = messages },
		})
	end)
end

-- ── Git subagent (ephemeral, custom message handler) ───────────────

--- @param prompt string
--- @param on_done fun(result: string)
function M.send_git_subagent(prompt, on_done)
	local cheap_models = {
		kiro = "claude-haiku-4.5",
		opencode = "github-copilot/gpt-4.1",
	}
	local model_id = cheap_models[opts.provider] or "claude-haiku-4.5"

	local agent_text = ""
	local git_phase = "set_model" -- after spawn_session: set_model → prompt → done

	--- Custom message handler for the git subagent
	local function git_handler(s, msg)
		if msg.id and not msg.method then
			if msg.error then
				vim.schedule(function()
					status.stop("Git agent error")
					vim.notify("lg-git: " .. vim.inspect(msg.error), vim.log.levels.ERROR)
				end)
				return
			end
			local result = msg.result or {}

			if git_phase == "set_model" then
				git_phase = "prompt"
				local id = s.next_id; s.next_id = id + 1
				write(s, {
					jsonrpc = "2.0", id = id, method = "session/prompt",
					params = { sessionId = s.session_id, prompt = { { type = "text", text = prompt } } },
				})

			elseif git_phase == "prompt" then
				if result.stopReason then
					git_phase = "done"
					vim.schedule(function()
						status.stop("Git analysis done")
						require("lg.ui.window").finish_subagent()
						on_done(agent_text)
						vim.defer_fn(function()
							pcall(function() s.proc:kill(9) end)
						end, 500)
					end)
				end
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
						agent_text = agent_text .. content.text
						vim.schedule(function() require("lg.ui.window").append_subagent_text(content.text) end)
					end
				elseif update.sessionUpdate == "tool_call" then
					vim.schedule(function() status.update("Git: " .. (update.title or "unknown")) end)
				elseif update.sessionUpdate == "tool_call_update" and update.status == "error" then
					vim.schedule(function() status.flash("Git tool failed: " .. (update.message or "unknown")) end)
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
				write(s, { jsonrpc = "2.0", id = msg.id, result = { outcome = { outcome = "selected", optionId = option_id } } })
			end
		end
	end

	status.start("Git analysis (" .. model_id .. ")...")

	spawn_session({
		cmd = opts.cmd,
		mcp_servers = {},
		client_name = "lg-git",
		on_message = git_handler,
		on_fail = function()
			status.stop("Git agent failed")
			on_done("")
		end,
	}, function(s)
		if not s then return end

		-- First step after session ready: set model
		local id = s.next_id; s.next_id = id + 1
		write(s, {
			jsonrpc = "2.0", id = id, method = "session/set_model",
			params = { sessionId = s.session_id, modelId = model_id },
		})
	end)
end

-- ── Quick chat (ephemeral, opencode gpt-4.1) ──────────────────────

function M.send_quick_chat(prompt, on_done)
	local model_id = "github-copilot/gpt-4.1"
	local phase = "set_model"

	ephemeral_override = { provider = "opencode", model = model_id }

	local function handler(s, msg)
		if msg.id and not msg.method then
			if phase == "set_model" then
				phase = "prompt"
				local id = s.next_id; s.next_id = id + 1
				write(s, {
					jsonrpc = "2.0", id = id, method = "session/prompt",
					params = { sessionId = s.session_id, prompt = { { type = "text", text = prompt } } },
				})
			elseif phase == "prompt" and msg.result and msg.result.stopReason then
				vim.schedule(function()
					ephemeral_override = nil
					status.stop()
					vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestFinished" })
					if on_done then on_done() end
				end)
				vim.defer_fn(function() pcall(function() s.proc:kill(9) end) end, 500)
			end
			return
		end

		local method = msg.method or ""
		if method == "session/update" then
			local update = msg.params and msg.params.update
			if update and update.sessionUpdate == "agent_message_chunk" then
				local content = update.content
				if content and content.type == "text" and content.text then
					vim.schedule(function() require("lg.ui.window").append_agent_text(content.text) end)
				end
			end
		elseif method == "session/request_permission" then
			local tool_options = msg.params and msg.params.options or {}
			local option_id = tool_options[1] and tool_options[1].optionId
			if option_id and msg.id then
				write(s, { jsonrpc = "2.0", id = msg.id, result = { outcome = { outcome = "selected", optionId = option_id } } })
			end
		end
	end

	status.start("Quick chat (GPT-4.1)...")
	vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestStarted" })

	spawn_session({
		cmd = { "opencode", "acp" },
		mcp_servers = {},
		client_name = "lg-quick-chat",
		on_message = handler,
		on_fail = function()
			ephemeral_override = nil
			status.stop("Quick chat failed")
			if on_done then on_done() end
		end,
	}, function(s)
		if not s then return end
		local id = s.next_id; s.next_id = id + 1
		write(s, {
			jsonrpc = "2.0", id = id, method = "session/set_model",
			params = { sessionId = s.session_id, modelId = model_id },
		})
	end)
end

-- ── Planner mode (set_mode on main session) ───────────────────────

local _planner_active = false

function M.set_planner(enabled, callback)
	connect(function(s)
		if not s then
			if callback then callback(false) end
			return
		end
		local mode_id = enabled and "planner" or "kiro_default"
		local id = s.next_id; s.next_id = id + 1
		s.pending[id] = { _set_mode = true }
		write(s, {
			jsonrpc = "2.0", id = id, method = "session/set_mode",
			params = { sessionId = s.session_id, modeId = mode_id },
		})
		_planner_active = enabled
		if callback then callback(true) end
	end)
end

function M.is_planner_active()
	return _planner_active
end

function M.kill_planner()
	_planner_active = false
end

-- ── Hint / reviewer mode ──────────────────────────────────────────

function M.send_hint(prompt, regions, context_regions, on_done)
	connect(function(s)
		if not s then return end

		-- Switch to reviewer mode
		local id = s.next_id; s.next_id = id + 1
		write(s, {
			jsonrpc = "2.0", id = id, method = "session/set_mode",
			params = { sessionId = s.session_id, modeId = "reviewer" },
		})

		-- For hints, all regions are read-only context — reviewer doesn't edit
		local all_ctx = {}
		for _, r in ipairs(regions) do all_ctx[#all_ctx + 1] = r end
		for _, r in ipairs(context_regions or {}) do all_ctx[#all_ctx + 1] = r end
		local has_scope = #regions > 0
		local messages = protocol.build_prompt({}, all_ctx, prompt, nil, nil, nil, has_scope and { scope = "hints" } or nil)
		vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestStarted" })

		s._on_done = function()
			-- Switch back to default mode
			local rid = s.next_id; s.next_id = rid + 1
			write(s, {
				jsonrpc = "2.0", id = rid, method = "session/set_mode",
				params = { sessionId = s.session_id, modeId = "lg" },
			})
			if on_done then on_done() end
		end

		local pid = s.next_id; s.next_id = pid + 1
		write(s, {
			jsonrpc = "2.0", id = pid, method = "session/prompt",
			params = { sessionId = s.session_id, prompt = messages },
		})
	end)
end

-- ── Hint subagent (ephemeral, doesn't block main session) ─────────

function M.send_hint_subagent(prompt, regions, context_regions, on_done)
	local phase = "set_mode"
	local tool_error = nil

	local all_ctx = {}
	for _, r in ipairs(regions) do all_ctx[#all_ctx + 1] = r end
	for _, r in ipairs(context_regions or {}) do all_ctx[#all_ctx + 1] = r end
	local has_scope = #regions > 0
	local messages = protocol.build_prompt({}, all_ctx, prompt, nil, nil, nil, has_scope and { scope = "hints" } or nil)

	local function handler(s, msg)
		if msg.id and not msg.method then
			if msg.error then
				vim.schedule(function()
					status.stop("Hint subagent error")
					status.flash("RPC error: " .. (msg.error.message or vim.inspect(msg.error)))
				end)
				return
			end

			if phase == "set_mode" then
				phase = "prompt"
				local id = s.next_id; s.next_id = id + 1
				write(s, {
					jsonrpc = "2.0", id = id, method = "session/prompt",
					params = { sessionId = s.session_id, prompt = messages },
				})
			elseif phase == "prompt" and msg.result and msg.result.stopReason then
				vim.schedule(function()
					if tool_error then
						status.flash("Tool error: " .. tool_error)
					end
					status.stop("Review done")
					require("lg.ui.window").finish_subagent()
					vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestFinished" })
					if on_done then on_done(tool_error) end
				end)
				vim.defer_fn(function() pcall(function() s.proc:kill(9) end) end, 500)
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
						vim.schedule(function() require("lg.ui.window").append_subagent_text(content.text) end)
					end
				elseif update.sessionUpdate == "tool_call" then
					vim.schedule(function()
						status.update("Tool: " .. (update.title or "unknown"))
					end)
				elseif update.sessionUpdate == "tool_call_update" and update.status == "error" then
					tool_error = update.message or update.title or "unknown error"
					vim.schedule(function()
						status.flash("Tool failed: " .. tool_error)
					end)
				end
			end
		elseif method == "session/request_permission" then
			local tool_options = msg.params and msg.params.options or {}
			local option_id
			for _, opt in ipairs(tool_options) do
				if opt.kind == "allow_always" or opt.kind == "allow_once" then
					option_id = opt.optionId; break
				end
			end
			option_id = option_id or (tool_options[1] and tool_options[1].optionId)
			if option_id and msg.id then
				write(s, { jsonrpc = "2.0", id = msg.id, result = { outcome = { outcome = "selected", optionId = option_id } } })
			end
		end
	end

	status.start("Reviewing (subagent)...")
	vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestStarted" })

	spawn_session({
		cmd = opts.cmd,
		mcp_servers = {},
		client_name = "lg-hint-sub",
		on_message = handler,
		on_fail = function()
			status.stop("Hint subagent failed")
			if on_done then on_done() end
		end,
	}, function(s)
		if not s then return end
		local id = s.next_id; s.next_id = id + 1
		write(s, {
			jsonrpc = "2.0", id = id, method = "session/set_mode",
			params = { sessionId = s.session_id, modeId = "reviewer" },
		})
	end)
end

-- ── Suggest (uses main session, switches to suggester mode) ───────

function M.send_suggest(prompt, regions, context_regions, on_done)
	connect(function(s)
		if not s then return end

		local id = s.next_id; s.next_id = id + 1
		write(s, {
			jsonrpc = "2.0", id = id, method = "session/set_mode",
			params = { sessionId = s.session_id, modeId = "suggester" },
		})

		local all_ctx = {}
		for _, r in ipairs(regions) do all_ctx[#all_ctx + 1] = r end
		for _, r in ipairs(context_regions or {}) do all_ctx[#all_ctx + 1] = r end
		local has_scope = #regions > 0
		local messages = protocol.build_prompt({}, all_ctx, prompt, nil, nil, nil, has_scope and { scope = "suggestions" } or nil)
		vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestStarted" })

		s._on_done = function()
			local rid = s.next_id; s.next_id = rid + 1
			write(s, {
				jsonrpc = "2.0", id = rid, method = "session/set_mode",
				params = { sessionId = s.session_id, modeId = "lg" },
			})
			if on_done then on_done() end
		end

		local pid = s.next_id; s.next_id = pid + 1
		write(s, {
			jsonrpc = "2.0", id = pid, method = "session/prompt",
			params = { sessionId = s.session_id, prompt = messages },
		})
	end)
end

-- ── Suggest subagent (ephemeral) ──────────────────────────────────

function M.send_suggest_subagent(prompt, regions, context_regions, on_done)
	local phase = "set_mode"
	local tool_error = nil

	local all_ctx = {}
	for _, r in ipairs(regions) do all_ctx[#all_ctx + 1] = r end
	for _, r in ipairs(context_regions or {}) do all_ctx[#all_ctx + 1] = r end
	local has_scope = #regions > 0
	local messages = protocol.build_prompt({}, all_ctx, prompt, nil, nil, nil, has_scope and { scope = "suggestions" } or nil)

	local function handler(s, msg)
		if msg.id and not msg.method then
			if msg.error then
				vim.schedule(function()
					status.stop("Suggest subagent error")
					status.flash("RPC error: " .. (msg.error.message or vim.inspect(msg.error)))
				end)
				return
			end

			if phase == "set_mode" then
				phase = "prompt"
				local id = s.next_id; s.next_id = id + 1
				write(s, {
					jsonrpc = "2.0", id = id, method = "session/prompt",
					params = { sessionId = s.session_id, prompt = messages },
				})
			elseif phase == "prompt" and msg.result and msg.result.stopReason then
				vim.schedule(function()
					if tool_error then
						status.flash("Tool error: " .. tool_error)
					end
					status.stop("Suggestions done")
					require("lg.ui.window").finish_subagent()
					vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestFinished" })
					if on_done then on_done(tool_error) end
				end)
				vim.defer_fn(function() pcall(function() s.proc:kill(9) end) end, 500)
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
						vim.schedule(function() require("lg.ui.window").append_subagent_text(content.text) end)
					end
				elseif update.sessionUpdate == "tool_call" then
					vim.schedule(function()
						status.update("Tool: " .. (update.title or "unknown"))
					end)
				elseif update.sessionUpdate == "tool_call_update" and update.status == "error" then
					tool_error = update.message or update.title or "unknown error"
					vim.schedule(function()
						status.flash("Tool failed: " .. tool_error)
					end)
				end
			end
		elseif method == "session/request_permission" then
			local tool_options = msg.params and msg.params.options or {}
			local option_id
			for _, opt in ipairs(tool_options) do
				if opt.kind == "allow_always" or opt.kind == "allow_once" then
					option_id = opt.optionId; break
				end
			end
			option_id = option_id or (tool_options[1] and tool_options[1].optionId)
			if option_id and msg.id then
				write(s, { jsonrpc = "2.0", id = msg.id, result = { outcome = { outcome = "selected", optionId = option_id } } })
			end
		end
	end

	status.start("Suggesting (subagent)...")
	vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestStarted" })

	spawn_session({
		cmd = opts.cmd,
		mcp_servers = {},
		client_name = "lg-suggest-sub",
		on_message = handler,
		on_fail = function()
			status.stop("Suggest subagent failed")
			if on_done then on_done() end
		end,
	}, function(s)
		if not s then return end
		local id = s.next_id; s.next_id = id + 1
		write(s, {
			jsonrpc = "2.0", id = id, method = "session/set_mode",
			params = { sessionId = s.session_id, modeId = "suggester" },
		})
	end)
end

return M
