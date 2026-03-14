--- Send: build prompt with prefixes and dispatch to ACP session

local paint = require("lg.ui.paint")
local context = require("lg.tools.context")
local session = require("lg.session.session")
local window = require("lg.ui.window")
local status = require("lg.status")

local spinners = require("lg.spinner.spinners")

local M = {}

--- Count diagnostics published by the lg-hint LSP
local function count_ai_diagnostics()
	local n = 0
	for _, client in ipairs(vim.lsp.get_clients({ name = "lg-hint" })) do
		local ns = vim.lsp.diagnostic.get_namespace(client.id, false)
		if ns then
			n = n + #vim.diagnostic.get(nil, { namespace = ns })
		end
	end
	return n
end

local sent_region_count = 0

function M.reset_region_count()
	sent_region_count = 0
end

--- @param opts? { prompt?: string, from_chat?: boolean }
function M.send(opts)
	opts = opts or {}
	local all_regions = paint.get_all()
	-- Only include regions painted since last send
	local regions = {}
	for i = sent_region_count + 1, #all_regions do
		regions[#regions + 1] = all_regions[i]
	end
	if #regions == 0 and not opts.from_chat then
		regions = all_regions -- fallback: nothing new, use all
	end

	local function do_send(prompt, flags)
		flags = flags or {}
		if prompt then
			sent_region_count = #all_regions
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
		if
			#regions == 0
			and not opts.from_chat
			and not flags.has_auto_paint
			and not flags.has_git
			and not flags.has_hint
			and not flags.has_suggest
			and not flags.has_help
		then
			vim.notify("lg: no painted regions", vim.log.levels.WARN)
			return
		end
		if not prompt or prompt == "" then
			return
		end

		if flags.has_git then
			local git_prompt = prompt:gsub("@GIT%s*", "")
			window.add_prompt(prompt)
			status.start("Git analysis (Haiku)...")
			session.send_git_subagent(
				"You are a git analysis assistant. Use the git tools to investigate the user's question. Be concise and specific — your output will be used as context for another AI.\n\n"
					.. git_prompt,
				function(result)
					vim.schedule(function()
						if result and result ~= "" then
							local full_prompt = "The following git analysis was already shown to the user by a subagent — do NOT repeat or summarize it. Just act on the user's request using this context.\n\nGit analysis:\n"
								.. result
								.. "\n\nUser request:\n"
								.. git_prompt
							if opts.from_chat then
								session.send_chat(full_prompt, function()
									vim.schedule(function() spinners.stop() end)
								end)
							else
								session.send(
									full_prompt,
									regions,
									context.get_all(),
									function()
										vim.schedule(function()
											spinners.stop()
											window.refresh()
										end)
									end
								)
							end
						else
							status.stop("Git analysis empty")
						end
					end)
				end
			)
			return
		end

		if flags.has_hint then
			prompt = prompt:gsub("@SUB%s*", "")
			prompt = prompt:gsub("@HINT%s*", "")
			window.add_prompt((flags.has_sub and "@SUB " or "") .. "@HINT " .. prompt)
			status.start("Reviewing" .. (flags.has_sub and " (subagent)" or "") .. "...")
			local spin = spinners.start(regions)
			local hint_fn = (flags.has_sub or session.is_busy()) and session.send_hint_subagent or session.send_hint
			local retried = false
			local ctx_regions = context.get_all()
			local before = count_ai_diagnostics()
			local function check_and_retry()
				vim.defer_fn(function()
					local n = count_ai_diagnostics() - before
					if not retried and n <= 0 then
						retried = true
						status.flash("No hints published — retrying")
						status.start("Retrying review…")
						hint_fn(
							"Your previous attempt produced zero diagnostics in the editor. You MUST call the lg_hint tool. If the tool errored, fix the arguments and try again.\n\n"
								.. prompt,
							regions,
							ctx_regions,
							function()
								vim.defer_fn(function()
									spin:stop()
									local n2 = count_ai_diagnostics() - before
									if n2 <= 0 then
										status.flash("Retry failed — no hints")
									end
									status.stop("Review done — " .. math.max(n2, 0) .. " hint(s)")
								end, 500)
							end
						)
					else
						spin:stop()
						status.stop("Review done — " .. n .. " hint(s)")
					end
				end, 500)
			end
			hint_fn(prompt, regions, ctx_regions, check_and_retry)
			return
		end

		if flags.has_suggest then
			prompt = prompt:gsub("@SUB%s*", "")
			prompt = prompt:gsub("@SUGGEST%s*", "")
			window.add_prompt((flags.has_sub and "@SUB " or "") .. "@SUGGEST " .. prompt)
			status.start("Suggesting" .. (flags.has_sub and " (subagent)" or "") .. "...")
			local spin = spinners.start(regions)
			local suggest_fn = (flags.has_sub or session.is_busy()) and session.send_suggest_subagent
				or session.send_suggest
			local retried = false
			local ctx_regions = context.get_all()
			local before = count_ai_diagnostics()
			local function check_and_retry()
				vim.defer_fn(function()
					local n = count_ai_diagnostics() - before
					if not retried and n <= 0 then
						retried = true
						status.flash("No suggestions published — retrying")
						status.start("Retrying suggestions…")
						suggest_fn(
							"Your previous attempt produced zero diagnostics in the editor. You MUST call the lg_suggest tool. If the tool errored, fix the arguments and try again.\n\n"
								.. prompt,
							regions,
							ctx_regions,
							function()
								vim.defer_fn(function()
									spin:stop()
									local n2 = count_ai_diagnostics() - before
									if n2 <= 0 then
										status.flash("Retry failed — no suggestions")
									end
									status.stop("Suggestions done — " .. math.max(n2, 0) .. " suggestion(s)")
								end, 500)
							end
						)
					else
						spin:stop()
						status.stop("Suggestions done — " .. n .. " suggestion(s)")
					end
				end, 500)
			end
			suggest_fn(prompt, regions, ctx_regions, check_and_retry)
			return
		end

		local tool_hints = {}
		if flags.has_help then
			prompt = prompt:gsub("@SUB%s*", "")
			prompt = prompt:gsub("@HELP%s*", "")
			window.add_prompt((flags.has_sub and "@SUB " or "") .. "@HELP " .. prompt)
			status.start("Help" .. (flags.has_sub and " (subagent)" or "") .. "...")
			local spin = spinners.start(regions)
			local is_fn = (flags.has_sub or session.is_busy()) and session.send_help_subagent
				or session.send_help
			local retried = false
			local ctx_regions = context.get_all()
			local before = count_ai_diagnostics()
			local function check_and_retry()
				vim.defer_fn(function()
					local n = count_ai_diagnostics() - before
					if not retried and n <= 0 then
						retried = true
						status.flash("No suggestions published — retrying")
						status.start("Retrying help…")
						is_fn(
							"Your previous attempt produced zero diagnostics. You MUST call both lg_paint_regions and lg_suggest. If a tool errored, fix the arguments and try again.\n\n"
								.. prompt,
							regions,
							ctx_regions,
							function()
								vim.defer_fn(function()
									spin:stop()
									local n2 = count_ai_diagnostics() - before
									if n2 <= 0 then
										status.flash("Retry failed — no suggestions")
									end
									status.stop("Help done — " .. math.max(n2, 0) .. " suggestion(s)")
								end, 500)
							end
						)
					else
						spin:stop()
						status.stop("Help done — " .. n .. " suggestion(s)")
					end
				end, 500)
			end
			is_fn(prompt, regions, ctx_regions, check_and_retry)
			return
		end
		if flags.has_auto_paint then
			prompt = prompt:gsub("@INFO%s*", "")
			local history = window.get_history()
			if history ~= "" then
				prompt = "Previous conversation:\n" .. history .. "\n\nNew request:\n" .. prompt
			end
			window.add_prompt("@INFO " .. prompt)
			status.start("Info paint (subagent)...")
			local spin = spinners.start(regions)
			local ctx_regions = context.get_all()
			session.send_info_subagent(prompt, regions, ctx_regions, function()
				vim.schedule(function()
					spin:stop()
				end)
			end)
			return
		end
		if flags.has_diag then
			prompt = prompt:gsub("@DIAG%s*", "")
			table.insert(
				tool_hints,
				"Use the get_diagnostics tool to check for LSP errors/warnings in open buffers before making edits."
			)
		end
		if flags.has_search then
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
		if flags.has_file_lsp then
			prompt = prompt:gsub("@FILE_LSP%s*", "")
			local lsp = require("lg.tools.lsp")
			local bufnr = vim.api.nvim_get_current_buf()
			local line_count = vim.api.nvim_buf_line_count(bufnr)
			local info, errors, warns = lsp.gather_diagnostics(bufnr, 1, line_count)
			if info ~= "" then
				local fname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":~:.")
				lsp_context = "LSP diagnostics for " .. fname .. ":\n" .. info
				local summary = fname .. " — " .. errors .. " error(s), " .. warns .. " warning(s)"
				window.add_tool(summary)
			end
		elseif flags.has_lsp then
			prompt = prompt:gsub("@LSP%s*", "")
			local lsp = require("lg.tools.lsp")
			local parts = {}
			local total_errors, total_warns, total_types = 0, 0, 0
			for _, r in ipairs(regions) do
				if vim.api.nvim_buf_is_valid(r.bufnr) then
					local info, e, w, t = lsp.gather(r.bufnr, r.start_line, r.end_line)
					if info ~= "" then
						local fname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(r.bufnr), ":~:.")
						table.insert(parts, "LSP info for " .. fname .. ":\n" .. info)
						total_errors = total_errors + e
						total_warns = total_warns + w
						total_types = total_types + t
					end
				end
			end
			if #parts > 0 then
				lsp_context = table.concat(parts, "\n\n")
				local summary = #parts
					.. " region(s): "
					.. total_errors
					.. "E "
					.. total_warns
					.. "W "
					.. total_types
					.. " types"
				window.add_tool(summary)
			end
		end

		local tsc_context = nil
		if flags.has_tsc then
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
					local spin = spinners.start(regions)
					if opts.from_chat then
						session.send_chat(prompt, function()
							vim.schedule(function()
								spin:stop()
							end)
						end)
					else
						session.send(prompt, regions, context.get_all(), function()
							vim.schedule(function()
								spin:stop()
								window.refresh()
							end)
						end, lsp_context, tsc_context)
					end
				end)
			)
			return
		end

		window.add_prompt(prompt)
		local send_regions = opts.from_chat and {} or regions
		local spin = spinners.start(regions)
		if opts.from_chat then
			session.send_chat(prompt, function()
				vim.schedule(function()
					spin:stop()
				end)
			end)
		else
			session.send(prompt, send_regions, context.get_all(), function()
				vim.schedule(function()
					spin:stop()
					window.refresh()
				end)
			end, lsp_context, tsc_context)
		end
	end

	if opts.prompt then
		local text = opts.prompt
		do_send(text, {
			has_file_lsp = text and text:match("@FILE_LSP") ~= nil,
			has_lsp = text and text:match("@LSP") ~= nil and not text:match("@FILE_LSP"),
			has_auto_paint = text and text:match("@INFO") ~= nil,
			has_git = text and text:match("@GIT") ~= nil,
			has_hint = text and text:match("@HINT") ~= nil,
			has_suggest = text and text:match("@SUGGEST") ~= nil,
			has_sub = text and text:match("@SUB") ~= nil,
			has_help = text and text:match("@HELP") ~= nil,
		})
	else
		require("lg.ui.prompt").open(do_send)
	end
end

return M
