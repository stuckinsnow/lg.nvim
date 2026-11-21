--- Window: side column with stacked section windows + interactive markdown chat

local paint = require("lg.ui.paint")
local session = require("lg.session.session")

local M = {}

local state = {
	bufs = {},
	wins = {},
	history = {},
	pending_approval = nil, -- { prompt: string, resolve: fun(allowed: boolean), tag?: any }
	context_pct = nil,
	metering_total = 0,
	metering_unit = "credits",
	last_turn_ms = nil,
}

local opts = {}

-- Helpers

local function win_valid(w)
	return w and vim.api.nvim_win_is_valid(w)
end
local function buf_valid(b)
	return b and vim.api.nvim_buf_is_valid(b)
end

local function make_buf(name, ft)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = ft
	vim.bo[buf].modifiable = false
	pcall(vim.api.nvim_buf_set_name, buf, name)
	vim.diagnostic.enable(false, { bufnr = buf })
	return buf
end

local function ensure_buf(key, ft)
	if buf_valid(state.bufs[key]) then
		return state.bufs[key]
	end
	state.bufs[key] = make_buf("lg://" .. key, ft)
	return state.bufs[key]
end

local function set_win_opts(w)
	vim.wo[w].number = false
	vim.wo[w].relativenumber = false
	vim.wo[w].signcolumn = "no"
	vim.wo[w].winfixwidth = true
	vim.wo[w].winfixheight = true
	vim.wo[w].wrap = true
	vim.wo[w].cursorline = false
	vim.wo[w].spell = false
	vim.wo[w].foldcolumn = "1"
end

local function darken_bg(bg, factor)
	if not bg then
		return nil
	end
	local r = math.floor(math.floor(bg / 65536) % 256 * factor)
	local g = math.floor(math.floor(bg / 256) % 256 * factor)
	local b = math.floor((bg % 256) * factor)
	return string.format("#%02x%02x%02x", r, g, b)
end

local function ensure_highlights()
	vim.api.nvim_set_hl(0, "LgTitle", { link = "Title", default = true })
	vim.api.nvim_set_hl(0, "LgSeparator", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "LgRegionId", { link = "Number", default = true })
	vim.api.nvim_set_hl(0, "LgFile", { link = "Directory", default = true })
	vim.api.nvim_set_hl(0, "LgStatus", { link = "DiagnosticOk", default = true })
	vim.api.nvim_set_hl(0, "LgCostNormal", { link = "DiagnosticHint", default = true })
	vim.api.nvim_set_hl(0, "LgCostWarn", { link = "DiagnosticWarn", default = true })
	vim.api.nvim_set_hl(0, "LgCostAlarm", { link = "DiagnosticError", default = true })
	vim.api.nvim_set_hl(0, "LgApproval", { link = "DiagnosticWarn", default = true })
	local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
	local prompt_bg = darken_bg(normal and normal.bg, 0.82) or "#181822"
	vim.api.nvim_set_hl(0, "LgPromptNormal", { bg = prompt_bg, default = true })
end

local function set_buf_content(buf, lines, hls)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	if hls then
		local ns = vim.api.nvim_create_namespace("lg_" .. buf)
		vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
		for _, hl in ipairs(hls) do
			local line, cs, ce, hg = hl[1], hl[2], hl[3], hl[4]
			if ce == -1 then
				ce = #lines[line + 1]
			end
			pcall(vim.api.nvim_buf_set_extmark, buf, ns, line, cs, { end_col = ce, hl_group = hg, priority = 100 })
		end
	end
	vim.bo[buf].modifiable = false
end

-- Renderers

local devlens_up = false
local function check_devlens()
	vim.system({ "curl", "-s", "-m", "1", "http://127.0.0.1:7890/status" }, {}, function(obj)
		devlens_up = obj.code == 0 and obj.stdout:find('"extension":true') ~= nil
	end)
end

local function render_status()
	check_devlens()
	local ok_icon, fail_icon = "●", "○"

	-- ACP: Go binary running + socket connected
	local acp = session.is_connected() and ok_icon or fail_icon

	-- MCP: unix socket server for paint_edit / get_painted_regions
	local svr = require("lg.session.server")
	local mcp = svr.get_sock_path() and ok_icon or fail_icon

	-- LSP: lg-hint client attached and its hint socket listening
	local lsp_ok = #vim.lsp.get_clients({ name = "lg-hint" }) > 0 and vim.uv.fs_stat("/dev/shm/lg-hint.sock") ~= nil
	local lsp = lsp_ok and ok_icon or fail_icon

	local devlens = devlens_up and ok_icon or fail_icon

	local plan = session.is_planner_active() and ok_icon or fail_icon
	local line = string.format("acp %s  mcp %s  lsp %s  lens %s  plan %s", acp, mcp, lsp, devlens, plan)

	if state.context_pct then
		line = line .. string.format("  󱙺 %.0f%%", state.context_pct)
	end

	return { line }, { { 0, 0, -1, "LgStatus" } }
end

local function render_regions()
	ensure_highlights()
	local lines = {}
	local hls = {}
	local regions = paint.get_all()
	table.insert(lines, "Editable Regions (" .. #regions .. ")")
	table.insert(hls, { 0, 0, -1, "LgTitle" })
	if #regions == 0 then
		table.insert(lines, "  (none)")
		table.insert(hls, { 1, 0, -1, "LgSeparator" })
	else
		for i, r in ipairs(regions) do
			local fname = r.file ~= "" and vim.fn.fnamemodify(r.file, ":~:.") or "[unnamed]"
			local txt = string.format("  [%d] %s:%d-%d", i - 1, fname, r.start_line, r.end_line)
			table.insert(lines, txt)
			local idx = #lines - 1
			table.insert(hls, { idx, 2, 2 + #tostring(i - 1) + 2, "LgRegionId" })
			table.insert(hls, { idx, 2 + #tostring(i - 1) + 3, -1, "LgFile" })
		end
	end
	return lines, hls
end

local function render_context()
	ensure_highlights()
	local lines = {}
	local hls = {}
	local ctx = require("lg.tools.context").get_all()
	table.insert(lines, "Context (" .. #ctx .. ")")
	table.insert(hls, { 0, 0, -1, "LgTitle" })
	if #ctx == 0 then
		table.insert(lines, "  (none)")
		table.insert(hls, { 1, 0, -1, "LgSeparator" })
	else
		for i, r in ipairs(ctx) do
			local fname = r.file ~= "" and vim.fn.fnamemodify(r.file, ":~:.") or "[unnamed]"
			local header = string.format("  [%d] %s:%d-%d", i - 1, fname, r.start_line, r.end_line)
			if r.label then
				header = header .. "  search: " .. r.label
			end
			table.insert(lines, header)
			local idx = #lines - 1
			table.insert(hls, { idx, 2, 2 + #tostring(i - 1) + 2, "LgRegionId" })
			table.insert(hls, { idx, 2 + #tostring(i - 1) + 3, -1, "LgFile" })
			for _, l in ipairs(r.lines or {}) do
				table.insert(lines, "    " .. l)
				table.insert(hls, { #lines - 1, 0, -1, "LgSeparator" })
			end
		end
	end
	local files = require("lg.tools.context").get_files()
	for _, f in ipairs(files) do
		table.insert(lines, "  📎 " .. vim.fn.fnamemodify(f, ":~:."))
		table.insert(hls, { #lines - 1, 0, -1, "LgFile" })
	end
	local dlens = require("lg.tools.context").get_devlens()
	for _, d in ipairs(dlens) do
		local label = "  🔍 DevLens: " .. table.concat(d.tokens, ", ")
		if d.component then
			label = label .. " (" .. d.component .. ")"
		end
		table.insert(lines, label)
		table.insert(hls, { #lines - 1, 0, -1, "LgFile" })
	end
	return lines, hls
end
local function is_noisy_tool(text)
	local lower = (text or ""):lower()
	return lower:find("read_buffer", 1, true) ~= nil
		or lower:find("read_file", 1, true) ~= nil
		or lower:find("reading ", 1, true) == 1
		or lower:find("grep", 1, true) ~= nil
		or lower:find("glob", 1, true) ~= nil
		or lower:find("get_painted_regions", 1, true) ~= nil
		or lower:find("get_diagnostics", 1, true) ~= nil
		or lower:find("get_hints", 1, true) ~= nil
end

local function render_chat()
	local lines = {}
	local tool_lines = {}
	local cost_lines = {} -- [line] = severity: "normal" | "warn" | "alarm"
	for _, entry in ipairs(state.history) do
		if entry.type == "prompt" then
			table.insert(lines, "")
			table.insert(lines, "# Me")
			table.insert(lines, "")
			for _, l in ipairs(vim.split(entry.text, "\n")) do
				table.insert(lines, l)
			end
		elseif entry.type == "result" then
			table.insert(lines, "")
			table.insert(lines, "# AI")
			table.insert(lines, "")
			for _, l in ipairs(vim.split(entry.text, "\n")) do
				table.insert(lines, l)
			end
		elseif entry.type == "agent" then
			if #lines == 0 or lines[#lines] ~= "" then
				table.insert(lines, "")
				table.insert(lines, "# AI")
				table.insert(lines, "")
			end
			for _, l in ipairs(vim.split(entry.text or "", "\n")) do
				table.insert(lines, l)
			end
		elseif entry.type == "tool" then
			if opts.verbose ~= false or not is_noisy_tool(entry.text) then
				table.insert(lines, "")
				table.insert(lines, "⚙ " .. entry.text)
				tool_lines[#lines] = true
			end
		elseif entry.type == "cost" then
			table.insert(lines, "")
			table.insert(lines, " " .. entry.text)
			cost_lines[#lines] = entry.severity or "normal"
		elseif entry.type == "status" then
			table.insert(lines, "")
			table.insert(lines, "🔀 " .. entry.text)
			tool_lines[#lines] = true
		end
	end
	if #lines == 0 then
		table.insert(lines, "")
	end
	return lines, tool_lines, cost_lines
end

-- Public API

function M.setup(user_opts)
	opts = vim.tbl_deep_extend("force", {
		width = 60,
		position = "right",
		chat_height_pct = 60,
		verbose = true,
	}, user_opts or {})
end

local function format_attached_images()
	local imgs = require("lg.tools.context").get_images()
	if #imgs == 0 then
		return nil
	end
	local image = require("lg.tools.image")
	local sizes = {}
	for _, img in ipairs(imgs) do
		table.insert(sizes, image.format_size(img.size))
	end
	local label = #imgs == 1 and "1 image attached" or (#imgs .. " images attached")
	return label .. " (" .. table.concat(sizes, ", ") .. ")"
end

function M.add_prompt(prompt)
	local img_label = format_attached_images()
	if img_label then
		prompt = prompt .. "\n🖼 [" .. img_label .. "]"
	end
	table.insert(state.history, { type = "prompt", text = prompt })
	M.refresh()
end

function M.get_history()
	local parts = {}
	for _, entry in ipairs(state.history) do
		if entry.type == "prompt" then
			table.insert(parts, "User: " .. entry.text)
		elseif entry.type == "result" or entry.type == "agent" then
			table.insert(parts, "Assistant: " .. entry.text)
		end
	end
	return table.concat(parts, "\n\n")
end

function M.add_result(text)
	table.insert(state.history, { type = "result", text = text })
	M.refresh()
end

function M.add_tool(text)
	table.insert(state.history, { type = "tool", text = text })
	M.refresh()
end

function M.add_status(text)
	table.insert(state.history, { type = "status", text = text })
	M.refresh()
end

function M.set_context_pct(pct)
	state.context_pct = pct
	if buf_valid(state.bufs.chat) and vim.api.nvim_get_current_buf() == state.bufs.chat then
		require("lg.kitty").set(pct)
	end
	M.refresh()
end

function M.get_context_pct()
	return state.context_pct
end

local function fmt_tokens(n)
	if n >= 1000000 then
		return string.format("%.2fM", n / 1000000)
	elseif n >= 1000 then
		return string.format("%.1fk", n / 1000)
	end
	return tostring(math.floor(n))
end

function M.add_metering(data)
	local val = tonumber(data.total) or 0
	local unit = data.unit or "credits"
	local ms = tonumber(data.turn_duration_ms) or 0
	state.metering_total = state.metering_total + val
	state.metering_unit = unit
	state.last_turn_ms = ms

	local parts = {}
	local severity = "normal"
	if unit == "tokens" then
		if val > 0 then
			local detail = ""
			local inp = tonumber(data.input_tokens)
			local out = tonumber(data.output_tokens)
			if inp and out then
				detail = string.format(" (%s in, %s out)", fmt_tokens(inp), fmt_tokens(out))
			end
			table.insert(parts, fmt_tokens(val) .. " tokens" .. detail)
		end
		if ms > 0 then
			table.insert(parts, string.format("%.1fs", ms / 1000))
		end
		table.insert(parts, "total " .. fmt_tokens(state.metering_total))
	else
		-- Severity thresholds; unit isn't checked since kiro reports "credits" for all models.
		if val > 10 then
			severity = "alarm"
		elseif val > 5 then
			severity = "warn"
		end

		-- Format: "0.077 credits · 8.1s · total 0.234"
		if val > 0 then
			table.insert(parts, string.format("%.3f %s", val, unit))
		end
		if ms > 0 then
			table.insert(parts, string.format("%.1fs", ms / 1000))
		end
		table.insert(parts, string.format("total %.3f", state.metering_total))
	end

	table.insert(state.history, {
		type = "cost",
		severity = severity,
		text = table.concat(parts, " · "),
	})
	M.refresh()
end

function M.reset_metering()
	state.metering_total = 0
	state.last_turn_ms = nil
	M.refresh()
end

function M.append_agent_text(chunk)
	local last = state.history[#state.history]
	if not last or last.type ~= "agent" then
		table.insert(state.history, { type = "agent", text = chunk })
	else
		last.text = last.text .. chunk
	end
	M.refresh()
end

function M.append_subagent_text(chunk)
	-- Each subagent run gets its own split; first chunk creates it
	if not state.sub_active then
		state.sub_splits = state.sub_splits or {}
		local num = #state.sub_splits + 1
		state.sub_active = { text = "# AI — Subagent " .. num .. "\n\n", buf = nil, win = nil }
		if win_valid(state.wins.context) then
			local ctx_win = state.wins.context
			-- Find the bottommost subagent split to insert after, or use context
			local after = ctx_win
			for _, s in ipairs(state.sub_splits or {}) do
				if win_valid(s.win) then
					after = s.win
				end
			end
			vim.api.nvim_set_current_win(after)
			vim.cmd("belowright 6split")
			state.sub_active.win = vim.api.nvim_get_current_win()
			state.sub_active.buf = vim.api.nvim_create_buf(false, true)
			vim.bo[state.sub_active.buf].buftype = "nofile"
			vim.bo[state.sub_active.buf].filetype = "markdown"
			vim.api.nvim_win_set_buf(state.sub_active.win, state.sub_active.buf)
			set_win_opts(state.sub_active.win)
			vim.wo[state.sub_active.win].winfixheight = true
			vim.keymap.set("n", "q", function()
				M.close_subagent()
			end, { buffer = state.sub_active.buf })
			if win_valid(state.wins.chat) then
				vim.api.nvim_set_current_win(state.wins.chat)
			end
		end
		state.sub_splits = state.sub_splits or {}
		table.insert(state.sub_splits, state.sub_active)
	end
	local sa = state.sub_active
	sa.text = sa.text .. chunk
	if buf_valid(sa.buf) then
		local lines = vim.split(sa.text, "\n")
		vim.bo[sa.buf].modifiable = true
		vim.api.nvim_buf_set_lines(sa.buf, 0, -1, false, lines)
		vim.bo[sa.buf].modifiable = false
		if win_valid(sa.win) then
			pcall(vim.api.nvim_win_set_cursor, sa.win, { #lines, 0 })
			vim.api.nvim_win_set_height(sa.win, math.max(6, math.min(#lines, 15)))
		end
	end
end

--- Mark current subagent run as finished so next one gets a new split
function M.finish_subagent()
	state.sub_active = nil
	table.insert(state.history, { type = "tool", text = "Subagent finished ✓" })
	M.refresh()
end

function M.close_subagent()
	for _, s in ipairs(state.sub_splits or {}) do
		if win_valid(s.win) then
			vim.api.nvim_win_close(s.win, true)
		end
		if buf_valid(s.buf) then
			vim.api.nvim_buf_delete(s.buf, { force = true })
		end
	end
	state.sub_splits = {}
	state.sub_active = nil
end

function M.is_open()
	return win_valid(state.wins.chat) and win_valid(state.wins.prompt)
end

--- True when the user is actively in Insert mode inside the prompt bar.
function M.is_prompt_insert()
	return win_valid(state.wins.prompt)
		and vim.api.nvim_get_current_win() == state.wins.prompt
		and vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
end

local function update_prompt_winbar()
	if not win_valid(state.wins.prompt) then
		return
	end
	if state.pending_approval then
		local escaped = state.pending_approval.prompt:gsub("%%", "%%%%")
		vim.wo[state.wins.prompt].winbar = "%#LgApproval# ⚠ " .. escaped .. " [y/n] %*"
	else
		local img_label = format_attached_images()
		if img_label then
			vim.wo[state.wins.prompt].winbar = "%#LgFile# 🖼 " .. img_label .. " [Alt-x clear] %*"
		else
			vim.wo[state.wins.prompt].winbar = ""
		end
	end
end

--- Show a pending approval prompt directly above the prompt bar.
--- @param prompt string
--- @param on_resolve fun(allowed: boolean)
--- @param tag? any optional identifier so external resolvers can clear it
function M.show_approval(prompt, on_resolve, tag)
	state.pending_approval = { prompt = prompt, resolve = on_resolve, tag = tag }
	update_prompt_winbar()
end

--- Check if a pending approval with the given tag is currently shown.
--- @param tag any
--- @return boolean
function M.has_approval(tag)
	return state.pending_approval ~= nil and state.pending_approval.tag == tag
end

--- Resolve the currently displayed approval prompt (if any).
--- @param allowed boolean
--- @return boolean resolved
function M.resolve_approval(allowed)
	local pending = state.pending_approval
	if not pending then
		return false
	end
	state.pending_approval = nil
	update_prompt_winbar()
	pcall(pending.resolve, allowed)
	return true
end

local function parse_yn(text)
	local lower = vim.trim(text):lower()
	if lower == "y" or lower == "yes" then
		return true
	elseif lower == "n" or lower == "no" then
		return false
	end
	return nil
end

--- Get user input from the prompt bar buffer and send it
function M.submit()
	local buf = state.bufs.prompt
	if not buf_valid(buf) then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local text = vim.trim(table.concat(lines, "\n"))
	local has_images = #require("lg.tools.context").get_images() > 0
	if text == "" and not has_images then
		return
	end
	if text == "" then
		text = "See attached image(s)."
	end

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })

	if state.pending_approval then
		local decision = parse_yn(text)
		if decision ~= nil then
			M.resolve_approval(decision)
			return
		end
	end

	-- Include the active file name so the AI knows what the user is looking at
	local active_file
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		local b = vim.api.nvim_win_get_buf(win)
		if vim.bo[b].buftype == "" and vim.api.nvim_buf_get_name(b) ~= "" then
			active_file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":~:.")
			break
		end
	end
	if active_file then
		text = "[Current file: " .. active_file .. "]\n" .. text
	end

	require("lg").send({ prompt = text, from_chat = true })
end

--- Focus the prompt bar input area
function M.focus_input()
	if not win_valid(state.wins.prompt) then
		M.open()
	end
	if win_valid(state.wins.prompt) then
		vim.api.nvim_set_current_win(state.wins.prompt)
		local buf = state.bufs.prompt
		if buf_valid(buf) then
			local lc = vim.api.nvim_buf_line_count(buf)
			vim.api.nvim_win_set_cursor(state.wins.prompt, { lc, 0 })
			vim.cmd("startinsert!")
		end
	end
end

function M.refresh()
	local sections = { "status", "regions", "context" }
	local renderers = {
		status = render_status,
		regions = render_regions,
		context = render_context,
	}
	for _, key in ipairs(sections) do
		if win_valid(state.wins[key]) then
			local lines, hls = renderers[key]()
			set_buf_content(ensure_buf(key, "lg"), lines, hls)
			vim.api.nvim_win_set_height(state.wins[key], #lines)
		end
	end

	if win_valid(state.wins.chat) then
		local buf = ensure_buf("chat", "markdown")
		local prev_lc = vim.api.nvim_buf_line_count(buf)
		local cur_win = vim.api.nvim_get_current_win()
		local cursor_row = cur_win == state.wins.chat and vim.api.nvim_win_get_cursor(state.wins.chat)[1] or prev_lc
		local was_at_bottom = cursor_row >= prev_lc

		local lines, tool_lines, cost_lines = render_chat()
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modifiable = false

		local ns = vim.api.nvim_create_namespace("lg_chat")
		vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
		for ln in pairs(tool_lines) do
			vim.api.nvim_buf_set_extmark(buf, ns, ln - 1, 0, {
				end_col = #"⚙",
				hl_group = "LgToolIcon",
			})
			vim.api.nvim_buf_set_extmark(buf, ns, ln - 1, #"⚙", {
				end_row = ln - 1,
				end_col = #lines[ln],
				hl_group = "LgTool",
			})
		end
		if cost_lines then
			for ln, severity in pairs(cost_lines) do
				local hl = severity == "alarm" and "LgCostAlarm"
					or severity == "warn" and "LgCostWarn"
					or "LgCostNormal"
				vim.api.nvim_buf_set_extmark(buf, ns, ln - 1, 0, {
					end_row = ln - 1,
					end_col = #lines[ln],
					hl_group = hl,
				})
			end
		end
		if was_at_bottom then
			local lc = vim.api.nvim_buf_line_count(buf)
			pcall(vim.api.nvim_win_set_cursor, state.wins.chat, { lc, 0 })
		end
	end
	update_prompt_winbar()
end

local function setup_chat_keymaps(buf)
	vim.keymap.set("n", "<CR>", function()
		M.focus_input()
	end, { buffer = buf, desc = "Focus prompt bar" })
	vim.keymap.set("n", "i", function()
		M.focus_input()
	end, { buffer = buf, desc = "Focus prompt bar" })
	vim.keymap.set("n", "a", function()
		M.focus_input()
	end, { buffer = buf, desc = "Focus prompt bar" })
	vim.keymap.set("n", "q", function()
		M.close_subagent()
	end, { buffer = buf, desc = "Close subagent" })
end

local function setup_prompt_keymaps(buf)
	vim.keymap.set({ "n", "i" }, "<C-s>", function()
		M.submit()
	end, { buffer = buf, desc = "Send prompt" })
	vim.keymap.set("n", "<CR>", function()
		M.submit()
	end, { buffer = buf, desc = "Send prompt" })
	vim.keymap.set("i", "<CR>", function()
		if state.pending_approval then
			local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			local decision = parse_yn(table.concat(lines, "\n"))
			if decision ~= nil then
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
				M.resolve_approval(decision)
				return
			end
		end
		local cr = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
		vim.api.nvim_feedkeys(cr, "n", false)
	end, { buffer = buf, desc = "Approve/reject or newline" })
	local function paste_image(fallback_text)
		local image = require("lg.tools.image")
		local img, err = image.read_clipboard()
		if img then
			if not require("lg.tools.context").add_image(img) then
				vim.notify("lg: image already attached", vim.log.levels.INFO)
				return
			end
			M.refresh()
			return
		end
		if fallback_text then
			local text = vim.fn.getreg("+")
			if text ~= "" then
				vim.api.nvim_paste(text, false, -1)
				return
			end
		end
		vim.notify("lg: " .. (err or "no image in clipboard"), vim.log.levels.WARN)
	end
	vim.keymap.set("i", "<C-v>", function() paste_image(true) end, { buffer = buf, desc = "Paste clipboard image (or text)" })
	vim.keymap.set({ "n", "i" }, "<M-v>", function() paste_image(false) end, { buffer = buf, desc = "Paste clipboard image" })
	vim.keymap.set({ "n", "i" }, "<M-x>", function()
		local ctx = require("lg.tools.context")
		if #ctx.get_images() == 0 then
			return
		end
		ctx.clear_images()
		M.refresh()
		vim.notify("lg: cleared attached images", vim.log.levels.INFO)
	end, { buffer = buf, desc = "Clear attached images" })
end

local _opening = false

function M.open()
	if win_valid(state.wins.status) then
		return
	end

	_opening = true
	local aug = vim.api.nvim_create_augroup("lg_window", { clear = true })
	local prev_win = vim.api.nvim_get_current_win()
	local cmd = opts.position == "left" and "topleft" or "botright"

	vim.cmd(cmd .. " " .. opts.width .. "vsplit")
	state.wins.status = vim.api.nvim_get_current_win()
	local status_buf = ensure_buf("status", "lg")
	vim.api.nvim_win_set_buf(state.wins.status, status_buf)
	set_win_opts(state.wins.status)

	vim.cmd("belowright 1split")
	state.wins.regions = vim.api.nvim_get_current_win()
	local regions_buf = ensure_buf("regions", "lg")
	vim.api.nvim_win_set_buf(state.wins.regions, regions_buf)
	set_win_opts(state.wins.regions)

	vim.cmd("belowright 1split")
	state.wins.context = vim.api.nvim_get_current_win()
	local context_buf = ensure_buf("context", "lg")
	vim.api.nvim_win_set_buf(state.wins.context, context_buf)
	set_win_opts(state.wins.context)

	vim.cmd("belowright split")
	state.wins.chat = vim.api.nvim_get_current_win()
	local chat_buf = ensure_buf("chat", "markdown")
	vim.api.nvim_win_set_buf(state.wins.chat, chat_buf)
	set_win_opts(state.wins.chat)
	vim.wo[state.wins.chat].winfixheight = false
	vim.wo[state.wins.chat].conceallevel = 2
	vim.bo[chat_buf].modifiable = false

	setup_chat_keymaps(chat_buf)

	vim.cmd("belowright 3split")
	state.wins.prompt = vim.api.nvim_get_current_win()
	local prompt_buf = ensure_buf("prompt", "markdown")
	vim.api.nvim_win_set_buf(state.wins.prompt, prompt_buf)
	set_win_opts(state.wins.prompt)
	vim.wo[state.wins.prompt].winfixheight = true
	vim.wo[state.wins.prompt].winhighlight = "Normal:LgPromptNormal,NormalNC:LgPromptNormal"
	vim.bo[prompt_buf].modifiable = true

	setup_prompt_keymaps(prompt_buf)

	local function is_sidebar_win(w)
		for _, key in ipairs({ "status", "regions", "context", "chat", "prompt" }) do
			if state.wins[key] == w then
				return true
			end
		end
		return false
	end

	-- Entering the lg sidebar from outside (e.g. <C-l> from code) lands in the
	-- prompt bar; moving inside the sidebar (<C-k>/<C-j>) stays unrestricted.
	for _, b in ipairs({ status_buf, regions_buf, context_buf, chat_buf }) do
		vim.api.nvim_create_autocmd("WinEnter", {
			group = aug,
			buffer = b,
			callback = function()
				if _opening then
					return
				end
				local prev = vim.fn.win_getid(vim.fn.winnr("#"))
				if is_sidebar_win(prev) then
					return
				end
				local target = win_valid(state.wins.prompt) and state.wins.prompt
				if target then
					vim.schedule(function()
						if win_valid(target) then
							pcall(vim.api.nvim_set_current_win, target)
						end
					end)
				end
			end,
		})
	end

	for _, b in ipairs({ chat_buf, prompt_buf }) do
		vim.api.nvim_create_autocmd("BufEnter", {
			group = aug,
			buffer = b,
			callback = function()
				local pct = state.context_pct
				if pct then require("lg.kitty").set(pct) end
			end,
		})
		vim.api.nvim_create_autocmd("BufLeave", {
			group = aug,
			buffer = b,
			callback = function() require("lg.kitty").clear() end,
		})
	end

	_opening = false
	M.refresh()

	pcall(vim.api.nvim_set_current_win, state.wins.prompt)
end

function M.close()
	M.close_subagent()
	for _, key in ipairs({ "prompt", "chat", "context", "regions", "status" }) do
		if win_valid(state.wins[key]) then
			vim.api.nvim_win_close(state.wins[key], true)
		end
		state.wins[key] = nil
	end
end

function M.toggle()
	if win_valid(state.wins.status) then
		M.close()
	else
		M.open()
	end
end

function M.clear_history()
	state.history = {}
	state.metering_total = 0
	state.last_turn_ms = nil
	M.refresh()
end

function M.toggle_planner()
	session.set_planner(not session.is_planner_active(), function(ok)
		if ok then
			vim.schedule(function()
				M.refresh()
			end)
		end
	end)
end

return M
