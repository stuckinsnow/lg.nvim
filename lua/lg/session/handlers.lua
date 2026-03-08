--- Main session message handler
---
--- Handles: session/update (streaming, tool calls),
--- session/request_permission (create/delete confirm, auto-approve),
--- fs/read_text_file, fs/write_text_file (inline diff review).

local status = require("lg.status")

local M = {}

--- Auto-approve a permission request (picks allow_once/allow_always)
--- @param session lg.ProcessSession
--- @param msg table
function M.auto_approve(session, msg)
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
		session:write({
			jsonrpc = "2.0",
			id = msg.id,
			result = { outcome = { outcome = "selected", optionId = option_id } },
		})
	end
end

--- Full message handler for the main persistent session.
--- Handles streaming, hunk review, permission prompts, fs operations.
--- @param session lg.ProcessSession
--- @param msg table
function M.handle_main(session, msg)
	if session.killed then
		return
	end

	-- Response to our request
	if msg.id and not msg.method then
		if msg.result and msg.result.stopReason then
			local cb = session._on_done and session._on_done[msg.id]
			if cb then
				session._on_done[msg.id] = nil
			end
			vim.schedule(function()
				status.stop("Done")
				vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestFinished" })
				if cb then
					cb()
				end
			end)
		end
		return
	end

	local method = msg.method or ""

	if method == "session/update" then
		local update = msg.params and msg.params.update
		if not update then
			return
		end
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
			end)
		elseif update.sessionUpdate == "tool_call_update" and update.status == "error" then
			vim.schedule(function()
				status.flash("Tool failed: " .. (update.message or update.title or "unknown"))
			end)
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
			if
				title:match("^Creating ")
				or title:match("^Deleting ")
				or (title:match("^Running") and title:match("[:%s]rm "))
			then
				local reject_id
				for _, opt in ipairs(tool_options) do
					if opt.kind == "reject_once" or opt.kind == "reject_always" then
						reject_id = opt.optionId
						break
					end
				end
				vim.schedule(function()
					vim.ui.select({ "Allow", "Reject" }, { prompt = title .. "?" }, function(choice)
						local oid = choice == "Allow" and option_id or reject_id or option_id
						session:write({
							jsonrpc = "2.0",
							id = msg.id,
							result = { outcome = { outcome = "selected", optionId = oid } },
						})
						status.update(choice == "Allow" and ("Approved: " .. title) or ("Rejected: " .. title))
					end)
				end)
			else
				vim.schedule(function()
					status.update("Approved: " .. title)
				end)
				session:write({
					jsonrpc = "2.0",
					id = msg.id,
					result = { outcome = { outcome = "selected", optionId = option_id } },
				})
			end
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
			session:write({ jsonrpc = "2.0", id = msg.id, result = { content = content } })
		end
	elseif method == "fs/write_text_file" then
		local path = msg.params and msg.params.path
		local content = msg.params and msg.params.content or ""
		if path and msg.id then
			local resolved = vim.fn.fnamemodify(path, ":p")
			vim.schedule(function()
				status.update("Writing: " .. vim.fn.fnamemodify(path, ":t"))
			end)
			local f = io.open(resolved, "w")
			if f then
				f:write(content)
				f:close()
			end
			session:write({ jsonrpc = "2.0", id = msg.id, result = vim.NIL })
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

return M
