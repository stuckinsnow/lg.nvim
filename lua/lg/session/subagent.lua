--- Subagent: ephemeral ACP sessions for isolated tasks.

local client = require("lg.session.client")
local protocol = require("lg.session.protocol")
local status = require("lg.status")

local M = {}

--- @type fun(on_ready: fun(ok: boolean))
M._ensure_acp = nil
--- @type fun(mode_id: string): string
M._resolve_mode = nil
--- @type fun(): table
M._opts = nil

--- Set a subagent's model and wait for the ACP confirmation event.
---
--- OpenCode can return an incomplete model/config list from the initial
--- `session/new` response. For example, the provider may initially report
--- `opencode/hy4-flash-free` as the current model and not yet include
--- `github-copilot/auto` in its model options. A later
--- `config_option_update` can then add `github-copilot/auto` to the list.
---
--- This matters because the lg-acp `set_model` acknowledgement only means
--- that the request was accepted by lg-acp; it does not mean that OpenCode
--- has applied the model or even finished discovering it. If we sent the
--- prompt immediately, the request could run on the initial free model
--- instead. That can produce a misleading provider.free-limit error even
--- though the requested model was never used.
---
--- Therefore this helper waits for the later model-list update, retries the
--- selection once the requested model is advertised, and then waits for the
--- provider's confirmed current-model update before sending any prompt. A
--- single deadline remains so a provider that never reports the model cannot
--- leave the subagent hanging forever.
---
--- TODO: Make this more elegant. Replace this compatibility flow with a
--- first-class ACP model-selection operation that atomically discovers,
--- selects, and confirms the provider's default/model without requiring
--- client-side retry coordination. Revisit this when a better model-selection
--- API or model is available.
--- @param session_id string
--- @param model_id string
--- @param on_done fun(ok: boolean)
local function set_model_confirmed(session_id, model_id, on_done)
	local finished = false
	local request_pending = false
	local unsubscribe
	local unsubscribe_models

	local function request_model()
		if finished or request_pending then
			return
		end
		request_pending = true
		client.set_model(session_id, model_id, function(resp)
			request_pending = false
			if resp and resp.ok == true then
				local current
				for _, option in ipairs(resp.data and resp.data.configOptions or {}) do
					if option.id == "model" then
						current = option.currentValue
						break
					end
				end
				if current == model_id and not finished then
					finished = true
					unsubscribe_models()
					unsubscribe()
					on_done(true)
				end
			elseif resp and resp.error and not resp.error:find("model not found", 1, true) and not finished then
				finished = true
				unsubscribe_models()
				unsubscribe()
				on_done(false)
			end
		end)
	end

	unsubscribe = client.on("model_changed", function(ev)
		if ev.session_id == session_id and ev.text == model_id then
			finished = true
			unsubscribe_models()
			unsubscribe()
			on_done(true)
		end
	end)
	unsubscribe_models = client.on("models_updated", function(ev)
		if ev.session_id ~= session_id or type(ev.data) ~= "table" then
			return
		end
		for _, option in ipairs(ev.data.configOptions or {}) do
			if option.id == "model" then
				for _, candidate in ipairs(option.options or {}) do
					if candidate.value == model_id then
						request_model()
						return
					end
				end
			end
		end
	end)

	request_model()
	-- A broken provider must not leave the subagent waiting forever, but this
	-- is a single deadline rather than a polling loop.
	vim.defer_fn(function()
		if not finished then
			finished = true
			unsubscribe_models()
			unsubscribe()
			on_done(false)
		end
	end, 5000)
end

--- Generic subagent: creates a new session on the Go side, runs lifecycle, cleans up.
--- @param config { mode_id?: string, prompt: table, model_id?: string, label: string, on_text?: fun(text:string), on_done: fun(text:string, tool_error:string?), on_fail?: fun(), track_tool_errors?: boolean, finish_subagent?: boolean, fire_autocmds?: boolean, manual_permissions?: boolean }
function M.run(config)
	status.start(config.label .. "...")
	if config.fire_autocmds ~= false then
		vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestStarted" })
	end

	M._ensure_acp(function(ok)
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

			-- A failed turn never emits prompt_done, so tear down here too or the
			-- handlers, session and spinner all leak.
			unsubs[#unsubs + 1] = client.on("prompt_error", function(ev)
				if ev.session_id ~= sub_sid then
					return
				end
				for _, unsub in ipairs(unsubs) do
					unsub()
				end
				client.destroy_session(sub_sid)

				local model_check = require("lg.session.model-check")
				local explanation = model_check.explain_error(ev.error, nil, M._opts().provider)
				local reason = explanation or ev.error or "unknown"
				status.stop(config.label .. " failed")
				vim.notify("lg: " .. config.label .. " failed — " .. reason, vim.log.levels.ERROR)

				if config.finish_subagent ~= false then
					require("lg.ui.window").finish_subagent()
				end
				if config.fire_autocmds ~= false then
					vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestFinished" })
				end
				if config.on_fail then
					config.on_fail()
				else
					config.on_done(agent_text, tool_error)
				end
			end)

			unsubs[#unsubs + 1] = client.on("permission_request", function(ev)
				if ev.session_id ~= sub_sid then
					return
				end
				local data = ev.data
				if type(data) == "string" then
					local ok2, parsed = pcall(vim.json.decode, data)
					if ok2 then
						data = parsed
					end
				end
				local options = data.options or {}

				if config.manual_permissions then
					local rpc_id = data.rpc_id
					require("lg.ui.approval").permission(data.title or "Permission request", options, function(oid)
						client.respond_permission(sub_sid, rpc_id, oid)
					end)
				else
					-- Prefer allow_once: on kiro v3, allow_always writes a persistent rule.
					local oid
					for _, opt in ipairs(options) do
						if opt.kind == "allow_once" or (not oid and opt.kind == "allow_always") then
							oid = opt.optionId
						end
					end
					if oid then
						client.respond_permission(sub_sid, data.rpc_id, oid)
					end
				end
			end)

			-- Lifecycle: [set_model] → [set_mode] → prompt
			local function send_prompt()
				client.prompt(sub_sid, config.prompt)
			end

			local function set_mode_then_prompt()
				if config.mode_id then
					client.set_mode(sub_sid, M._resolve_mode(config.mode_id), function()
						send_prompt()
					end)
				else
					send_prompt()
				end
			end

			-- Without an explicit model, follow the main session's model. A new
			-- opencode session otherwise starts on opencode's default, which
			-- can be a rate-limited free model.
			local model_id = config.model_id or require("lg.session.models").current_model()
			if model_id then
				set_model_confirmed(sub_sid, model_id, function(ok)
					if ok then
						set_mode_then_prompt()
					elseif config.on_fail then
						for _, unsub in ipairs(unsubs) do
							unsub()
						end
						client.destroy_session(sub_sid)
						status.stop(config.label .. " failed")
						config.on_fail()
					else
						for _, unsub in ipairs(unsubs) do
							unsub()
						end
						client.destroy_session(sub_sid)
						status.stop(config.label .. " failed")
						config.on_done("", "model was not applied")
					end
				end)
			else
				set_mode_then_prompt()
			end
		end)
	end)
end

-- ── Convenience wrappers ───────────────────────────────────────────

function M.send_oneshot(prompt, regions, context_regions, on_done)
	local svr = require("lg.session.server")
	-- The MCP process does not reliably inherit a per-session LG_SESSION value.
	-- Use an explicit token so get_painted_regions and paint_edit address this
	-- temporary quick-edit region instead of falling back to global paint.
	local edit_token = svr.create_token(regions)
	local messages = protocol.build_prompt(regions, context_regions or {}, prompt, nil, nil, edit_token)
	local provider = M._opts().provider
	local model_id = provider == "opencode" and "github-copilot/auto" or "auto"

	M.run({
		mode_id = "lg-oneshot",
		model_id = model_id,
		prompt = messages,
		label = "Quick edit (" .. model_id .. ")",
		finish_subagent = false,
		track_tool_errors = false,
		on_done = function()
			svr.remove_token(edit_token)
			if on_done then
				on_done()
			end
		end,
		on_fail = function()
			svr.remove_token(edit_token)
			if on_done then
				on_done()
			end
		end,
	})
end

function M.send_shell(prompt, on_done)
	M.run({
		mode_id = "lg-shell",
		prompt = { { type = "text", text = prompt } },
		label = "Shell",
		manual_permissions = true,
		on_done = function(text)
			on_done(text)
		end,
		on_fail = function()
			status.stop("Shell agent failed")
			on_done("")
		end,
	})
end

function M.send_git(prompt, on_done)
	local cheap = { kiro = "claude-haiku-4.5", opencode = "github-copilot/auto" }
	local model_id = cheap[M._opts().provider] or "claude-haiku-4.5"

	M.run({
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

function M.send_devlens(prompt, on_done)
	local cheap = { kiro = "claude-haiku-4.5", opencode = "github-copilot/auto" }
	local model_id = cheap[M._opts().provider] or "claude-haiku-4.5"

	M.run({
		mode_id = "devlens",
		prompt = { { type = "text", text = prompt } },
		model_id = model_id,
		label = "DevLens (" .. model_id .. ")",
		on_done = function(text)
			on_done(text)
		end,
		on_fail = function()
			status.stop("DevLens agent failed")
			on_done("")
		end,
	})
end

function M.send_quick_chat(prompt, on_done, set_override, clear_override)
	local model_id = "github-copilot/auto"
	set_override({ provider = "opencode", model = model_id })

	M.run({
		prompt = { { type = "text", text = prompt } },
		model_id = model_id,
		label = "Quick chat (Copilot auto)",
		finish_subagent = false,
		on_text = function(text)
			require("lg.ui.window").append_agent_text(text)
		end,
		on_done = function()
			clear_override()
			if on_done then
				on_done()
			end
		end,
		on_fail = function()
			clear_override()
			status.stop("Quick chat failed")
			if on_done then
				on_done()
			end
		end,
	})
end

--- Generic mode subagent (hint, suggest, help, info).
--- @param config { mode_id: string, scope?: string, label: string, track_tool_errors?: boolean }
function M.send_mode_subagent(config, prompt, regions, context_regions, on_done)
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

	M.run({
		mode_id = config.mode_id,
		prompt = messages,
		label = config.label,
		track_tool_errors = config.track_tool_errors,
		on_done = function(_, tool_error)
			if on_done then
				on_done(tool_error)
			end
		end,
	})
end

return M
