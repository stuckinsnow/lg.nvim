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
				if ev.session_id ~= sub_sid then return end
				agent_text = agent_text .. ev.text
				if config.on_text then
					config.on_text(ev.text)
				else
					require("lg.ui.window").append_subagent_text(ev.text)
				end
			end)

			unsubs[#unsubs + 1] = client.on("tool_call", function(ev)
				if ev.session_id ~= sub_sid then return end
				status.update(config.label .. ": " .. (ev.text or "unknown"))
			end)

			unsubs[#unsubs + 1] = client.on("tool_error", function(ev)
				if ev.session_id ~= sub_sid then return end
				if config.track_tool_errors ~= false then
					tool_error = ev.text or "unknown error"
				end
				status.flash("Tool failed: " .. (ev.text or "unknown"))
			end)

			unsubs[#unsubs + 1] = client.on("prompt_done", function(ev)
				if ev.session_id ~= sub_sid then return end
				for _, unsub in ipairs(unsubs) do unsub() end
				client.destroy_session(sub_sid)
				if tool_error then status.flash("Tool error: " .. tool_error) end
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
				if ev.session_id ~= sub_sid then return end
				local data = ev.data
				if type(data) == "string" then
					local ok2, parsed = pcall(vim.json.decode, data)
					if ok2 then data = parsed end
				end
				local options = data.options or {}

				if config.manual_permissions then
					local title = data.title or "Permission request"
					local rpc_id = data.rpc_id
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
						if oid then client.respond_permission(sub_sid, rpc_id, oid) end
					end)
				else
					local oid
					for _, opt in ipairs(options) do
						if opt.kind == "allow_always" or opt.kind == "allow_once" then
							oid = opt.optionId
							break
						end
					end
					if oid then client.respond_permission(sub_sid, data.rpc_id, oid) end
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

-- ── Convenience wrappers ───────────────────────────────────────────

function M.send_oneshot(prompt, regions, context_regions, on_done)
	local svr = require("lg.session.server")
	local sid = svr.register_session(regions)
	local messages = protocol.build_prompt(regions, context_regions or {}, prompt)

	M.run({
		mode_id = "lg-oneshot",
		prompt = messages,
		label = "Quick edit",
		finish_subagent = false,
		track_tool_errors = false,
		on_done = function()
			svr.unregister_session(sid)
			if on_done then on_done() end
		end,
		on_fail = function()
			svr.unregister_session(sid)
		end,
	})
end

function M.send_shell(prompt, on_done)
	M.run({
		mode_id = "lg-shell",
		prompt = { { type = "text", text = prompt } },
		label = "Shell",
		manual_permissions = true,
		on_done = function(text) on_done(text) end,
		on_fail = function()
			status.stop("Shell agent failed")
			on_done("")
		end,
	})
end

function M.send_git(prompt, on_done)
	local cheap = { kiro = "claude-haiku-4.5", opencode = "github-copilot/gpt-4.1" }
	local model_id = cheap[M._opts().provider] or "claude-haiku-4.5"

	M.run({
		prompt = { { type = "text", text = prompt } },
		model_id = model_id,
		label = "Git analysis (" .. model_id .. ")",
		on_done = function(text) on_done(text) end,
		on_fail = function()
			status.stop("Git agent failed")
			on_done("")
		end,
	})
end

function M.send_devlens(prompt, on_done)
	local cheap = { kiro = "claude-haiku-4.5", opencode = "github-copilot/gpt-4.1" }
	local model_id = cheap[M._opts().provider] or "claude-haiku-4.5"

	M.run({
		mode_id = "devlens",
		prompt = { { type = "text", text = prompt } },
		model_id = model_id,
		label = "DevLens (" .. model_id .. ")",
		on_done = function(text) on_done(text) end,
		on_fail = function()
			status.stop("DevLens agent failed")
			on_done("")
		end,
	})
end

function M.send_quick_chat(prompt, on_done, set_override, clear_override)
	local model_id = "github-copilot/gpt-4.1"
	set_override({ provider = "opencode", model = model_id })

	M.run({
		prompt = { { type = "text", text = prompt } },
		model_id = model_id,
		label = "Quick chat (GPT-4.1)",
		finish_subagent = false,
		on_text = function(text)
			require("lg.ui.window").append_agent_text(text)
		end,
		on_done = function()
			clear_override()
			if on_done then on_done() end
		end,
		on_fail = function()
			clear_override()
			status.stop("Quick chat failed")
			if on_done then on_done() end
		end,
	})
end

--- Generic mode subagent (hint, suggest, help, info).
--- @param config { mode_id: string, scope?: string, label: string, track_tool_errors?: boolean }
function M.send_mode_subagent(config, prompt, regions, context_regions, on_done)
	local all_ctx = {}
	for _, r in ipairs(regions) do all_ctx[#all_ctx + 1] = r end
	for _, r in ipairs(context_regions or {}) do all_ctx[#all_ctx + 1] = r end
	local has_scope = #regions > 0
	local extra = (config.scope and has_scope) and { scope = config.scope } or nil
	local messages = protocol.build_prompt({}, all_ctx, prompt, nil, nil, nil, extra)

	M.run({
		mode_id = config.mode_id,
		prompt = messages,
		label = config.label,
		track_tool_errors = config.track_tool_errors,
		on_done = function(_, tool_error)
			if on_done then on_done(tool_error) end
		end,
	})
end

return M
