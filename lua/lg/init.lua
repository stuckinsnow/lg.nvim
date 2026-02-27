--- lg: Paint regions + direct kiro-cli ACP for constrained AI editing

local paint = require("lg.paint")
local context = require("lg.context")
local diff = require("lg.diff")
local session = require("lg.session")
local server = require("lg.server")
local window = require("lg.window")
local status = require("lg.status")

local spinners = require("lg.spinners")

local M = {}

function M.setup(opts)
	opts = opts or {}
	spinners.setup(opts)
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
	require("lg.send").send(opts)
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
	require("lg.hunk").clear()
	require("lg.changes").clear()
end

-- ── Diff hunks (chat mode) ────────────────────────────────────────

local hunk = require("lg.hunk")
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

-- ── UI ─────────────────────────────────────────────────────────────

function M.toggle_window()
	window.toggle()
end

function M.focus_chat()
	window.focus_input()
end

-- ── Search / context ───────────────────────────────────────────────

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

-- ── Git ────────────────────────────────────────────────────────────

function M.paint_from_commits()
	require("lg.paint-commits").pick()
end

function M.list_regions()
	require("lg.paint-commits").list_regions()
end

return M
