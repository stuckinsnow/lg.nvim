--- Send: build prompt with prefixes and dispatch to ACP session

local paint = require("lg.paint")
local context = require("lg.context")
local session = require("lg.session")
local window = require("lg.window")
local status = require("lg.status")

local spinners = require("lg.spinners")

local M = {}

--- Snapshot git diff, return callback that highlights new changes
--- @param snap_opts? { skip_qf?: boolean }
local function git_snapshot_cb(snap_opts)
	snap_opts = snap_opts or {}
	local baseline = nil
	vim.system({ "git", "diff", "--unified=0" }, {}, function(obj)
		baseline = (obj.code == 0 and obj.stdout) or ""
	end)
	return function()
		vim.system({ "git", "diff", "--unified=0" }, {}, vim.schedule_wrap(function(obj)
			local current = (obj.code == 0 and obj.stdout) or ""
			if current == baseline then return end
			local cwd = vim.fn.getcwd() .. "/"
			local items = {}
			local file
			for line in current:gmatch("[^\n]+") do
				local f = line:match("^%+%+%+ b/(.+)")
				if f then file = cwd .. f end
				if file then
					local s = line:match("^@@ .+ %+(%d+)")
					if s then
						table.insert(items, { file = file, line = tonumber(s) })
					end
				end
			end
			if #items > 0 then
				local old_hunks = {}
				local bf
				for line in baseline:gmatch("[^\n]+") do
					local f = line:match("^%+%+%+ b/(.+)")
					if f then bf = cwd .. f end
					if bf then
						local s = line:match("^@@ .+ %+(%d+)")
						if s then old_hunks[bf .. ":" .. s] = true end
					end
				end
				local new_items = {}
				for _, item in ipairs(items) do
					if not old_hunks[item.file .. ":" .. item.line] then
						table.insert(new_items, item)
					end
				end
				if #new_items > 0 then
					require("lg.changes").set(new_items, { skip_qf = snap_opts.skip_qf })
				end
			end
		end))
	end
end

--- @param opts? { prompt?: string, from_chat?: boolean }
function M.send(opts)
	opts = opts or {}
	local regions = paint.get_all()

	local function do_send(prompt, has_lsp, has_tsc, has_diag, has_search, has_auto_paint, has_git, has_hint, has_sub)
		if prompt then
			local active
			for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
				local b = vim.api.nvim_win_get_buf(win)
				if vim.bo[b].buftype == "" and vim.api.nvim_buf_get_name(b) ~= "" then
					active = vim.api.nvim_buf_get_name(b)
					break
				end
			end
			if active then
				prompt = prompt:gsub("#buffdir", "@" .. vim.fn.fnamemodify(active, ":~:.:h") .. "/")
				prompt = prompt:gsub("#buffer", "@" .. vim.fn.fnamemodify(active, ":~:."))
			end
			prompt = prompt:gsub("#%./", "@")
		end
		if #regions == 0 and not opts.from_chat and not has_auto_paint and not has_git and not has_hint then
			vim.notify("lg: no painted regions", vim.log.levels.WARN)
			return
		end
		if not prompt or prompt == "" then return end

		if has_git then
			local git_prompt = prompt:gsub("@GIT%s*", "")
			window.add_prompt(prompt)
			status.start("Git analysis (Haiku)...")
			session.send_git_subagent(
				"You are a git analysis assistant. Use the git tools to investigate the user's question. Be concise and specific — your output will be used as context for another AI.\n\n" .. git_prompt,
				function(result)
					vim.schedule(function()
						if result and result ~= "" then
							local full_prompt = "The following git analysis was already shown to the user by a subagent — do NOT repeat or summarize it. Just act on the user's request using this context.\n\nGit analysis:\n" .. result .. "\n\nUser request:\n" .. git_prompt
							local send_regions = opts.from_chat and {} or regions
							session.send(full_prompt, send_regions, opts.from_chat and {} or context.get_all(), function()
								vim.schedule(function() spinners.stop() end)
							end)
						else
							status.stop("Git analysis empty")
						end
					end)
				end
			)
			return
		end

		if has_hint then
			prompt = prompt:gsub("@SUB%s*", "")
			prompt = prompt:gsub("@HINT%s*", "")
			window.add_prompt((has_sub and "@SUB " or "") .. "@HINT " .. prompt)
			status.start("Reviewing" .. (has_sub and " (subagent)" or "") .. "...")
			spinners.start(regions)
			local hint_fn = has_sub and session.send_hint_subagent or session.send_hint
			hint_fn(prompt, regions, context.get_all(), function()
				vim.schedule(function()
					spinners.stop()
					status.stop("Review done")
				end)
			end)
			return
		end

		local tool_hints = {}
		if has_auto_paint then
			prompt = prompt:gsub("@INFO%s*", "")
			local history = window.get_history()
			if history ~= "" then
				prompt = "Previous conversation:\n" .. history .. "\n\nNew request:\n" .. prompt
			end
			table.insert(tool_hints, "Use the lg_paint_regions tool to highlight the code regions that need editing. Do NOT write any code — explain what changes are needed in technical terms only. Paint every region that would need modification.")
		end
		if has_diag then
			prompt = prompt:gsub("@DIAG%s*", "")
			table.insert(tool_hints, "Use the get_diagnostics tool to check for LSP errors/warnings in open buffers before making edits.")
		end
		if has_search then
			prompt = prompt:gsub("@SEARCH%s*", "")
			table.insert(tool_hints, "Use the lg_search_codebase tool first to find relevant code — it uses nomic-embed-text semantic search over the codebase. Fall back to your own search tools if needed.")
		end
		if #tool_hints > 0 then
			prompt = table.concat(tool_hints, "\n") .. "\n\n" .. prompt
		end

		local lsp_context = nil
		if has_lsp then
			prompt = prompt:gsub("@LSP%s*", "")
			local lsp = require("lg.lsp")
			local parts = {}
			for _, r in ipairs(regions) do
				if vim.api.nvim_buf_is_valid(r.bufnr) then
					local info = lsp.gather(r.bufnr, r.start_line, r.end_line)
					if info ~= "" then
						local fname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(r.bufnr), ":~:.")
						table.insert(parts, "LSP info for " .. fname .. ":\n" .. info)
						window.add_result("LSP info for " .. fname .. ":\n" .. info)
					end
				end
			end
			if #parts > 0 then lsp_context = table.concat(parts, "\n\n") end
			window.refresh()
		end

		local tsc_context = nil
		if has_tsc then
			prompt = prompt:gsub("@TSC%s*", "")
			status.start("Running tsc…")
			vim.system({ "tsc", "--noEmit" }, {}, vim.schedule_wrap(function(obj)
				if obj.code ~= 0 and obj.stdout ~= "" then
					tsc_context = obj.stdout
					window.add_result("tsc --noEmit:\n" .. obj.stdout)
				else
					window.add_result("tsc: no errors")
				end
				window.refresh()
				status.stop("tsc done")

				window.add_prompt(prompt)
				local sr = opts.from_chat and {} or regions
				spinners.start(regions)
				local on_done = opts.from_chat and git_snapshot_cb({ skip_qf = not has_auto_paint }) or nil
				session.send(prompt, sr, opts.from_chat and {} or context.get_all(), function()
					vim.schedule(function()
						spinners.stop()
						if on_done then on_done() end
					end)
				end, lsp_context, tsc_context)
			end))
			return
		end

		window.add_prompt(prompt)
		local send_regions = opts.from_chat and {} or regions
		spinners.start(regions)
		local on_done = opts.from_chat and git_snapshot_cb({ skip_qf = not has_auto_paint }) or nil
		session.send(prompt, send_regions, opts.from_chat and {} or context.get_all(), function()
			vim.schedule(function()
				spinners.stop()
				if on_done then on_done() end
			end)
		end, lsp_context, tsc_context)
	end

	if opts.prompt then
		local text = opts.prompt
		local has_ap = text:match("@INFO") ~= nil
		local has_git = text:match("@GIT") ~= nil
		local has_hint = text:match("@HINT") ~= nil
		local has_sub = text:match("@SUB") ~= nil
		do_send(text, false, false, false, false, has_ap, has_git, has_hint, has_sub)
	else
		require("lg.prompt").open(do_send)
	end
end

return M
