--- Generic ephemeral subagent
---
--- Spawns a new ACP session (on a shared or dedicated process),
--- runs a lifecycle: [set_model] → [set_mode] → prompt → done,
--- then cleans up.

local status = require("lg.status")
local handlers = require("lg.session.handlers")

local M = {}

--- Run an ephemeral subagent session.
---
--- For kiro: reuses the shared process (no extra spawn cost).
--- For opencode / custom cmd: spawns a dedicated process.
---
--- Lifecycle: [set_model] → [set_mode] → prompt → done → cleanup
---
--- @param process lg.Process  shared process to create session on
--- @param config { mode_id?: string, prompt: table, model_id?: string, label: string, on_text?: fun(text:string), on_done: fun(text:string, tool_error:string?), on_fail?: fun(), track_tool_errors?: boolean, finish_subagent?: boolean, fire_autocmds?: boolean }
function M.run(process, config)
	local agent_text = ""
	local tool_error = nil
	local phase = (config.model_id and "set_model") or (config.mode_id and "set_mode") or "prompt"

	local function advance(session)
		if phase == "set_model" then
			phase = config.mode_id and "set_mode" or "prompt"
		elseif phase == "set_mode" then
			phase = "prompt"
		end
		if phase == "set_mode" then
			local id = session:next_rpc_id()
			session:track_response(id)
			session:write({
				jsonrpc = "2.0",
				id = id,
				method = "session/set_mode",
				params = { sessionId = session.session_id, modeId = config.mode_id },
			})
		elseif phase == "prompt" then
			local id = session:next_rpc_id()
			session:track_response(id)
			session:write({
				jsonrpc = "2.0",
				id = id,
				method = "session/prompt",
				params = { sessionId = session.session_id, prompt = config.prompt },
			})
		end
	end

	local function on_message(session, msg)
		-- Response routing
		if msg.id and not msg.method then
			if msg.error then
				vim.schedule(function()
					status.stop(config.label .. " error")
					status.flash("RPC error: " .. (msg.error.message or vim.inspect(msg.error)))
				end)
				return
			end

			if phase == "set_model" or phase == "set_mode" then
				advance(session)
			elseif phase == "prompt" and msg.result and msg.result.stopReason then
				-- Done — clean up session from process
				process:remove_session(session.session_id)
				vim.schedule(function()
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
			end
			return
		end

		-- Notifications
		local method = msg.method or ""
		if method == "session/update" then
			local update = msg.params and msg.params.update
			if not update then
				return
			end
			if update.sessionUpdate == "agent_message_chunk" then
				local content = update.content
				if content and content.type == "text" and content.text then
					agent_text = agent_text .. content.text
					if config.on_text then
						vim.schedule(function()
							config.on_text(content.text)
						end)
					else
						vim.schedule(function()
							require("lg.ui.window").append_subagent_text(content.text)
						end)
					end
				end
			elseif update.sessionUpdate == "tool_call" then
				vim.schedule(function()
					status.update(config.label .. ": " .. (update.title or "unknown"))
				end)
			elseif update.sessionUpdate == "tool_call_update" and update.status == "error" then
				if config.track_tool_errors ~= false then
					tool_error = update.message or update.title or "unknown error"
				end
				vim.schedule(function()
					status.flash("Tool failed: " .. (update.message or update.title or "unknown"))
				end)
			end
		elseif method == "session/request_permission" then
			handlers.auto_approve(session, msg)
		end
	end

	status.start(config.label .. "...")
	if config.fire_autocmds ~= false then
		vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestStarted" })
	end

	process:create_session(on_message, {}, function(session)
		if not session then
			status.stop(config.label .. " failed")
			if config.on_fail then
				config.on_fail()
			else
				config.on_done("", nil)
			end
			return
		end

		if config.model_id then
			local id = session:next_rpc_id()
			session:track_response(id)
			session:write({
				jsonrpc = "2.0",
				id = id,
				method = "session/set_model",
				params = { sessionId = session.session_id, modelId = config.model_id },
			})
		elseif config.mode_id then
			local id = session:next_rpc_id()
			session:track_response(id)
			session:write({
				jsonrpc = "2.0",
				id = id,
				method = "session/set_mode",
				params = { sessionId = session.session_id, modeId = config.mode_id },
			})
		else
			-- No model or mode — go straight to prompt
			local id = session:next_rpc_id()
			session:track_response(id)
			session:write({
				jsonrpc = "2.0",
				id = id,
				method = "session/prompt",
				params = { sessionId = session.session_id, prompt = config.prompt },
			})
		end
	end)
end

return M
