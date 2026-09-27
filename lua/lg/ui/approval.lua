--- Serialised approval prompts.
---
--- Agents can issue several tool calls in parallel, each needing approval. Pickers
--- behind vim.ui.select (fzf-lua, snacks, telescope) usually allow one instance at
--- a time, so a second prompt replaces the first and the first callback never
--- fires, leaving the agent waiting forever. Every agent-triggered prompt goes
--- through this queue so only one is on screen at a time.

local M = {}

local queue = {}
local active = false

local function next_prompt()
	if active then
		return
	end
	local item = table.remove(queue, 1)
	if not item then
		return
	end
	active = true
	local done = false
	local opts = item.opts
	if #queue > 0 then
		opts = vim.tbl_extend("force", opts, { prompt = (opts.prompt or "") .. " (+" .. #queue .. " queued)" })
	end
	vim.ui.select(item.items, opts, function(choice, idx)
		if done then
			return
		end
		done = true
		active = false
		-- Run the callback, then show the next prompt once the picker has closed.
		pcall(item.on_choice, choice, idx)
		vim.schedule(next_prompt)
	end)
end

--- Queued drop-in for vim.ui.select.
--- @param items any[]
--- @param opts table
--- @param on_choice fun(choice: any?, idx: integer?)
function M.select(items, opts, on_choice)
	table.insert(queue, { items = items, opts = opts, on_choice = on_choice })
	vim.schedule(next_prompt)
end

--- Ask Allow/Reject for an ACP permission request.
--- @param title string
--- @param options { optionId: string, kind: string }[] ACP permission options
--- @param respond fun(option_id: string, allowed: boolean)
function M.permission(title, options, respond)
	local reject_id, allow_id
	for _, opt in ipairs(options or {}) do
		if not reject_id and (opt.kind == "reject_once" or opt.kind == "reject_always") then
			reject_id = opt.optionId
		end
		if not allow_id and (opt.kind == "allow_always" or opt.kind == "allow_once") then
			allow_id = opt.optionId
		end
	end

	M.select({ "Allow", "Reject" }, { prompt = title .. "?" }, function(choice)
		local allowed = choice == "Allow"
		local oid = allowed and allow_id or reject_id or allow_id
		if oid then
			respond(oid, allowed)
		end
	end)
end

--- Number of prompts on screen or waiting (for tests / status).
function M.pending()
	return #queue + (active and 1 or 0)
end

return M
