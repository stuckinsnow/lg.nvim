--- lg: Paint regions + direct kiro-cli ACP for constrained AI editing

local paint = require("lg.ui.paint")
local context = require("lg.tools.context")
local diff = require("lg.ui.diff")
local session = require("lg.session.session")
local server = require("lg.session.server")
local window = require("lg.ui.window")
local status = require("lg.status")

local spinners = require("lg.spinner.spinners")

local M = {}

function M.setup(opts)
	opts = opts or {}
	spinners.setup(opts)
	paint.setup(opts.paint or {})
	session.setup(opts.session or {})
	window.setup(opts.window or {})

	server.start()

	-- Start hint LSP
	local plugin_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
	local lsp_bin = plugin_dir .. "/lsp/lg-lsp"
	if vim.fn.executable(lsp_bin) == 1 then
		vim.api.nvim_create_autocmd("FileType", {
			group = vim.api.nvim_create_augroup("lg_hint_lsp", { clear = true }),
			callback = function(ev)
				if vim.bo[ev.buf].buftype ~= "" then
					return
				end
				vim.lsp.start({
					name = "lg-hint",
					cmd = { lsp_bin },
					root_dir = vim.fn.getcwd(),
				}, { bufnr = ev.buf })
			end,
		})
		-- Attach to already-open buffers
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			if
				vim.api.nvim_buf_is_loaded(buf)
				and vim.bo[buf].buftype == ""
				and vim.api.nvim_buf_get_name(buf) ~= ""
			then
				vim.lsp.start({
					name = "lg-hint",
					cmd = { lsp_bin },
					root_dir = vim.fn.getcwd(),
				}, { bufnr = buf })
			end
		end
	end

	-- Register blink.cmp completion source for @ prefixes
	pcall(function()
		local blink = require("blink.cmp") ---@type table
		local add = blink.add_source_provider or blink.add_provider
		add("lg", {
			name = "lg",
			module = "lg.completion",
			enabled = true,
			score_offset = 100,
		})
		pcall(function()
			blink.add_filetype_source("lgprompt", "lg")
		end)
		pcall(function()
			blink.add_filetype_source("markdown", "lg")
		end)
	end)

	vim.api.nvim_create_autocmd("VimLeavePre", {
		callback = function()
			server.stop()
		end,
	})
end

-- ── Paint ──────────────────────────────────────────────────────────

function M.paint()
	local buf = vim.api.nvim_get_current_buf()
	local start_line = vim.fn.getpos("'<")[2]
	local end_line = vim.fn.getpos("'>")[2]
	paint.add(buf, start_line, end_line)
	window.refresh()
end

function M.context_paint()
	local buf = vim.api.nvim_get_current_buf()
	local start_line = vim.fn.getpos("'<")[2]
	local end_line = vim.fn.getpos("'>")[2]
	context.add(buf, start_line, end_line)
	window.refresh()
end

function M.mark_paint()
	local buf = vim.api.nvim_get_current_buf()
	local start_line = vim.fn.getpos("'<")[2]
	local end_line = vim.fn.getpos("'>")[2]
	server.add_info_region(buf, start_line, end_line)
end

-- ── Send ───────────────────────────────────────────────────────────

function M.send(opts)
	require("lg.session.send").send(opts)
end

function M.quick_edit()
	require("lg.quick-edit").quick_edit()
end

function M.quick_chat()
	require("lg.quick-chat").quick_chat()
end

-- ── Clear ──────────────────────────────────────────────────────────

function M.clear()
	paint.clear()
	require("lg.session.send").reset_region_count()
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
	require("lg.ui.hunk").clear()
end

function M.clear_hints()
	for _, client in ipairs(vim.lsp.get_clients({ name = "lg-hint" })) do
		local diag_ns = vim.lsp.diagnostic.get_namespace(client.id, false)
		if diag_ns then
			vim.diagnostic.reset(diag_ns)
		end
	end
end

-- ── Diff hunks (chat mode) ────────────────────────────────────────

local hunk = require("lg.ui.hunk")
function M.accept_hunk()
	hunk.accept()
end
function M.reject_hunk()
	hunk.reject()
end

-- ── Info paint ─────────────────────────────────────────────────────

function M.accept_info_paint()
	local count = server.convert_info_paint()
	window.refresh()
	vim.notify("lg: converted " .. count .. " info regions to paint", vim.log.levels.INFO)
end

function M.clear_info_paint()
	server.clear_info_paint()
end

function M.copy_info_paint()
	local regions = server.get_info_regions()
	if #regions == 0 then
		vim.notify("lg: no info paint regions to copy", vim.log.levels.WARN)
		return
	end
	local cwd = vim.fn.getcwd() .. "/"
	local lines = {}
	for _, r in ipairs(regions) do
		if vim.api.nvim_buf_is_valid(r.bufnr) then
			local path = vim.api.nvim_buf_get_name(r.bufnr)
			if path:sub(1, #cwd) == cwd then
				path = path:sub(#cwd + 1)
			end
			local range = r.start_line == r.end_line and tostring(r.start_line) or (r.start_line .. "-" .. r.end_line)
			table.insert(lines, path .. ":" .. range)
		end
	end
	vim.fn.setreg("+", table.concat(lines, "\n"))
	vim.notify("lg: copied " .. #lines .. " info regions to clipboard", vim.log.levels.INFO)
end

-- ── Session ────────────────────────────────────────────────────────

function M.clear_session()
	spinners.stop()
	status.stop("Session cleared")
	paint.clear()
	context.clear()
	diff.clear()
	session.kill_planner()
	session.clear()
	window.clear_history()
	vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestFinished" })
end

function M.stop()
	spinners.stop()
	status.stop("Stopped")
	if session.is_active() then
		session.kill()
	end
	vim.api.nvim_exec_autocmds("User", { pattern = "LgRequestFinished" })
end

function M.select_model()
	session.select_model()
end

function M.select_provider()
	session.select_provider()
end

function M.info()
	session.info()
end

function M.restore_session()
	session.restore_session()
end

function M.compact()
	session.compact()
end

function M.execute_command(command)
	session.execute_command(command)
end

function M.available_commands()
	return session.available_commands()
end

-- ── UI ─────────────────────────────────────────────────────────────

function M.toggle_window()
	window.toggle()
end

function M.toggle_planner()
	window.toggle_planner()
end

function M.focus_chat()
	window.focus_input()
end

-- ── Search / context ───────────────────────────────────────────────

function M.search()
	require("lg.tools.search").open()
end

function M.find(query)
	require("lg.tools.search-index").find(query)
end

function M.register_repo()
	require("lg.tools.search-index").register()
end

function M.add_file(path)
	if path and path ~= "" then
		context.add_file(path)
		window.refresh()
		return
	end
	local actions = {
		{ label = "Paste path", fn = function()
			vim.ui.input({ prompt = "File path: ", completion = "file" }, function(p)
				if p and p ~= "" then
					context.add_file(p)
					window.refresh()
				end
			end)
		end },
		{ label = "Browse filesystem (mini.files)", fn = function()
			local mf = require("mini.files")
			mf.open("/", false)
			local group = vim.api.nvim_create_augroup("lg_minifiles_attach", { clear = true })
			vim.api.nvim_create_autocmd("User", {
				group = group,
				pattern = "MiniFilesBufferCreate",
				callback = function(ev)
					vim.keymap.set("n", "<CR>", function()
						local entry = mf.get_fs_entry()
						if not entry then return end
						if entry.fs_type == "directory" then
							mf.go_in()
							return
						end
						context.add_file(entry.path)
						window.refresh()
						mf.close()
						vim.notify("lg: attached " .. vim.fn.fnamemodify(entry.path, ":t"), vim.log.levels.INFO)
					end, { buffer = ev.data.buf_id, desc = "Attach file" })
				end,
			})
			vim.api.nvim_create_autocmd("User", {
				group = group,
				pattern = "MiniFilesExplorerClose",
				once = true,
				callback = function()
					vim.api.nvim_del_augroup_by_name("lg_minifiles_attach")
				end,
			})
		end },
		{ label = "Project files (fzf)", fn = function()
			require("fzf-lua").files({
				prompt = "Attach> ",
				winopts = { title = " Attach File ", title_pos = "center", height = 0.5, width = 0.6 },
				actions = {
					["default"] = function(selected)
						if not selected or #selected == 0 then return end
						for _, entry in ipairs(selected) do
							local file = require("fzf-lua").path.entry_to_file(entry).path
							if file then context.add_file(file) end
						end
						window.refresh()
					end,
				},
			})
		end },
	}
	vim.ui.select(
		vim.tbl_map(function(a) return a.label end, actions),
		{ prompt = "Attach file:" },
		function(_, idx)
			if idx then actions[idx].fn() end
		end
	)
end

function M.add_lsp_context()
	local regions = paint.get_all()
	if #regions == 0 then
		vim.notify("lg: no painted regions", vim.log.levels.WARN)
		return
	end
	local lsp = require("lg.tools.lsp")
	local parts = {}
	for _, r in ipairs(regions) do
		if vim.api.nvim_buf_is_valid(r.bufnr) then
			local info = lsp.gather(r.bufnr, r.start_line, r.end_line)
			if info ~= "" then
				local fname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(r.bufnr), ":~:.")
				table.insert(parts, "LSP: " .. fname .. "\n" .. info)
			end
		end
	end
	if #parts > 0 then
		local text = table.concat(parts, "\n\n")
		require("lg.session.send").set_lsp_context(text)
		window.add_result(text)
	end
	window.refresh()
end

function M.clear_lsp_context()
	require("lg.session.send").clear_lsp_context()
	vim.notify("lg: LSP context cleared", vim.log.levels.INFO)
end

-- ── Git ────────────────────────────────────────────────────────────

function M.paint_from_commits()
	require("lg.tools.paint-commits").pick()
end

function M.list_regions()
	require("lg.tools.paint-commits").list_regions()
end

function M.smart_paint()
	require("lg.tools.smart-paint").pick()
end

function M.clear_menu()
	local actions = {
		{
			icon = "󰏝",
			label = "Paint regions",
			fn = function()
				M.clear()
			end,
		},
		{
			icon = "󰗅",
			label = "Context regions",
			fn = function()
				M.clear_context()
			end,
		},
		{
			icon = "󰕍",
			label = "Last paint",
			fn = function()
				M.clear_last()
			end,
		},
		{
			icon = "󰈮",
			label = "Edit markers",
			fn = function()
				M.clear_marks()
			end,
		},
		{
			icon = "󰌪",
			label = "Info paint",
			fn = function()
				M.clear_info_paint()
			end,
		},
		{
			icon = "󱃓",
			label = "AI hints",
			fn = function()
				M.clear_hints()
			end,
		},
		{
			icon = "󰚃",
			label = "Session (full reset)",
			fn = function()
				M.clear_session()
			end,
		},
		{
			icon = "󰈈",
			label = "Follow highlights",
			fn = function()
				local ns = vim.api.nvim_create_namespace("lg_follow_read")
				for _, buf in ipairs(vim.api.nvim_list_bufs()) do
					if vim.api.nvim_buf_is_valid(buf) then
						vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
					end
				end
			end,
		},
		{
			icon = "󰗩",
			label = "Everything",
			fn = function()
				M.clear_session()
			end,
		},
	}

	local entries = {}
	for _, a in ipairs(actions) do
		table.insert(entries, a.icon .. "  " .. a.label)
	end

	require("fzf-lua").fzf_exec(entries, {
		prompt = "  ",
		winopts = {
			title = " 󰃢 Clear ",
			title_pos = "center",
			height = 0.35,
			width = 0.35,
		},
		actions = {
			["default"] = function(selected)
				if not selected or #selected == 0 then
					return
				end
				for i, e in ipairs(entries) do
					if e == selected[1] then
						actions[i].fn()
						return
					end
				end
			end,
		},
	})
end

function M.toggle_follow()
	local server = require("lg.session.server")
	local enabled = not server.get_follow_reads()
	server.set_follow_reads(enabled)
	vim.notify("Follow reads: " .. (enabled and "ON" or "OFF"), vim.log.levels.INFO)
end

return M
