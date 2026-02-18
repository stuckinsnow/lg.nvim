--- lg: Paint regions + direct kiro-cli ACP for constrained AI editing

local paint = require("lg.paint")
local context = require("lg.context")
local diff = require("lg.diff")
local session = require("lg.session")
local server = require("lg.server")
local window = require("lg.window")
local status = require("lg.status")

local M = {}

--- @type table[] active spinner pairs
local active_spinners = {}

local config = {
	spinner_type = "hint", -- "hint", "block", "center", or "wave"
}

function M.setup(opts)
	opts = opts or {}
	config = vim.tbl_deep_extend("force", config, opts)
	paint.setup(opts.paint or {})
	session.setup(opts.session or {})
	window.setup(opts.window or {})

	server.start()

	vim.api.nvim_create_autocmd("VimLeavePre", {
		callback = function()
			server.stop()
		end,
	})
end

--- Paint current visual selection (editable)
function M.paint()
	local buf = vim.api.nvim_get_current_buf()
	local start_line = vim.fn.getpos("'<")[2]
	local end_line = vim.fn.getpos("'>")[2]
	paint.add(buf, start_line, end_line)
	window.refresh()
end

--- Paint current visual selection as read-only context
function M.context_paint()
	local buf = vim.api.nvim_get_current_buf()
	local start_line = vim.fn.getpos("'<")[2]
	local end_line = vim.fn.getpos("'>")[2]
	context.add(buf, start_line, end_line)
	window.refresh()
end

--- Stop all active spinners
local function stop_spinners()
	for _, s in ipairs(active_spinners) do
		s:stop()
	end
	active_spinners = {}
end

--- Snapshot git diff, return callback that populates quickfix with new changes
local function git_snapshot_cb()
	local baseline = nil
	vim.system({ "git", "diff", "--unified=0" }, {}, function(obj)
		baseline = (obj.code == 0 and obj.stdout) or ""
	end)
	return function()
		vim.system({ "git", "diff", "--unified=0" }, {}, vim.schedule_wrap(function(obj)
			local current = (obj.code == 0 and obj.stdout) or ""
			if current == baseline then return end
			-- Parse new hunks not in baseline
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
					require("lg.changes").set(new_items)
				end
			end
		end))
	end
end

--- Start hint spinners on all painted regions
local function start_spinners(regions)
	stop_spinners()
	local spinner_module = config.spinner_type == "block" and "lg.block-spinner"
		or config.spinner_type == "center" and "lg.spinner"
		or config.spinner_type == "wave" and "lg.wave-spinner"
		or "lg.hint-spinner"
	local Spinner = require(spinner_module)
	for _, r in ipairs(regions) do
		local ns = vim.api.nvim_create_namespace("lg_spinner_" .. r.bufnr .. "_" .. r.start_line)
		local spinner = Spinner.new({
			bufnr = r.bufnr,
			ns_id = ns,
			line_num = r.start_line,
			start_line = r.start_line,
			end_line = r.end_line,
		})
		if spinner then
			spinner:start()
			table.insert(active_spinners, spinner)
		end
	end
end

--- Send painted regions + prompt to kiro-cli
--- @param opts? { prompt?: string, from_chat?: boolean }
function M.send(opts)
	opts = opts or {}
	local regions = paint.get_all()

	local function do_send(prompt, has_lsp, has_tsc, has_diag, has_search, has_auto_paint, has_git)
		if #regions == 0 and not opts.from_chat and not has_auto_paint and not has_git then
			vim.notify("lg: no painted regions", vim.log.levels.WARN)
			return
		end
		if not prompt or prompt == "" then
			return
		end

		if has_git then
			local git_prompt = prompt:gsub("@GIT%s*", "")
			window.add_prompt(prompt)
			status.start("Git analysis (Haiku)...")
			session.send_git_subagent(
				"You are a git analysis assistant. Use the git tools to investigate the user's question. Be concise and specific — your output will be used as context for another AI.\n\n" .. git_prompt,
				function(result)
					vim.schedule(function()
						if result and result ~= "" then
							-- Auto-inject into main session
							local full_prompt = "The following git analysis was already shown to the user by a subagent — do NOT repeat or summarize it. Just act on the user's request using this context.\n\nGit analysis:\n" .. result .. "\n\nUser request:\n" .. git_prompt
							local send_regions = opts.from_chat and {} or regions
							session.send(full_prompt, send_regions, opts.from_chat and {} or context.get_all(), function()
								vim.schedule(function() stop_spinners() end)
							end)
						else
							status.stop("Git analysis empty")
						end
					end)
				end
			)
			return
		end

		local tool_hints = {}
		if has_auto_paint then
			prompt = prompt:gsub("@INFO%s*", "")
			local history = window.get_history()
			if history ~= "" then
				prompt = "Previous conversation:\n" .. history .. "\n\nNew request:\n" .. prompt
			end
			table.insert(
				tool_hints,
				"Use the lg_paint_regions tool to highlight the code regions that need editing. Do NOT write any code — explain what changes are needed in technical terms only. Paint every region that would need modification."
			)
		end
		if has_diag then
			prompt = prompt:gsub("@DIAG%s*", "")
			table.insert(
				tool_hints,
				"Use the get_diagnostics tool to check for LSP errors/warnings in open buffers before making edits."
			)
		end
		if has_search then
			prompt = prompt:gsub("@SEARCH%s*", "")
			table.insert(
				tool_hints,
				"Use the lg_search_codebase tool first to find relevant code — it uses nomic-embed-text semantic search over the codebase. Fall back to your own search tools if needed."
			)
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
			if #parts > 0 then
				lsp_context = table.concat(parts, "\n\n")
			end
			window.refresh()
		end

		local tsc_context = nil
		if has_tsc then
			prompt = prompt:gsub("@TSC%s*", "")
			status.start("Running tsc…")
			vim.system(
				{ "tsc", "--noEmit" },
				{},
				vim.schedule_wrap(function(obj)
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
					start_spinners(regions)
					local on_done = opts.from_chat and git_snapshot_cb() or nil
					session.send(prompt, sr, opts.from_chat and {} or context.get_all(), function()
						vim.schedule(function()
							stop_spinners()
							if on_done then on_done() end
						end)
					end, lsp_context, tsc_context)
				end)
			)
			return
		end

		window.add_prompt(prompt)
		local send_regions = opts.from_chat and {} or regions
		start_spinners(regions)
		local on_done = opts.from_chat and git_snapshot_cb() or nil
		session.send(prompt, send_regions, opts.from_chat and {} or context.get_all(), function()
			vim.schedule(function()
				stop_spinners()
				if on_done then on_done() end
			end)
		end, lsp_context, tsc_context)
	end

	if opts.prompt then
		local text = opts.prompt
		local has_ap = text:match("@INFO") ~= nil
		local has_git = text:match("@GIT") ~= nil
		do_send(text, false, false, false, false, has_ap, has_git)
	else
		require("lg.prompt").open(do_send)
	end
end

function M.clear()
	paint.clear()
	window.refresh()
end
function M.clear_last()
	paint.clear_last()
	window.refresh()
end
function M.clear_context()
	context.clear()
	window.refresh()
end
function M.clear_context_last()
	context.clear_last()
	window.refresh()
end
function M.clear_all()
	paint.clear()
	context.clear()
	diff.clear()
	window.refresh()
end
function M.clear_marks()
	diff.clear()
	require("lg.changes").clear()
end
function M.accept_info_paint()
	local count = server.convert_info_paint()
	window.refresh()
	vim.notify("lg: converted " .. count .. " info regions to paint", vim.log.levels.INFO)
end
function M.clear_info_paint()
	server.clear_info_paint()
end

function M.clear_session()
	stop_spinners()
	require("lg.status").stop("Session cleared")
	paint.clear()
	context.clear()
	diff.clear()
	session.clear()
	window.clear_history()
	vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestFinished" })
end

function M.stop()
	stop_spinners()
	require("lg.status").stop("Stopped")
	-- Kill the subprocess to stop generation, but don't clear history.
	-- connect() will spawn a new one on next send.
	if session.is_active() then
		session.kill()
	end
	vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestFinished" })
end

function M.toggle_window()
	window.toggle()
end
function M.focus_chat()
	window.focus_input()
end
function M.search()
	require("lg.search").open()
end

function M.find(query)
	require("lg.search-index").find(query)
end

function M.register_repo()
	require("lg.search-index").register()
end
function M.add_file()
	vim.ui.input({ prompt = "File path: ", completion = "file" }, function(path)
		if not path or path == "" then
			return
		end
		context.add_file(path)
		window.refresh()
	end)
end
function M.select_model()
	session.select_model()
end
function M.select_provider()
	session.select_provider()
end

function M.add_lsp_context()
	local regions = paint.get_all()
	if #regions == 0 then
		vim.notify("lg: no painted regions", vim.log.levels.WARN)
		return
	end

	local lsp = require("lg.lsp")
	for _, r in ipairs(regions) do
		if vim.api.nvim_buf_is_valid(r.bufnr) then
			local info = lsp.gather(r.bufnr, r.start_line, r.end_line)
			if info ~= "" then
				window.add_result(
					"LSP: " .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(r.bufnr), ":~:.") .. "\n" .. info
				)
			end
		end
	end
	window.refresh()
end

--- Visual select → paint → prompt → send as isolated oneshot session
function M.quick_edit()
	local buf = vim.api.nvim_get_current_buf()
	local start_line = vim.fn.getpos("'<")[2]
	local end_line = vim.fn.getpos("'>")[2]
	paint.add(buf, start_line, end_line)
	window.refresh()

	local regions = { paint.get_all()[#paint.get_all()] } -- just the one we added

	require("lg.prompt").open(function(prompt, has_lsp)
		if not prompt or prompt == "" then
			return
		end

		if has_lsp then
			local lsp = require("lg.lsp")
			local r = regions[1]
			if vim.api.nvim_buf_is_valid(r.bufnr) then
				local info = lsp.gather(r.bufnr, r.start_line, r.end_line)
				if info ~= "" then
					prompt = prompt .. "\n\nLSP Information:\n" .. info
				end
			end
		end

		start_spinners(regions)
		session.send_oneshot(prompt, regions, {}, function()
			vim.schedule(function()
				stop_spinners()
				paint.clear_last()
				window.refresh()
			end)
		end)
	end)
end

return M
