--- lg: Paint regions + direct kiro-cli ACP for constrained AI editing

local paint = require("lg.paint")
local context = require("lg.context")
local diff = require("lg.diff")
local session = require("lg.session")
local server = require("lg.server")
local window = require("lg.window")

local M = {}

--- @type table[] active spinner pairs
local active_spinners = {}

local config = {
	spinner_type = "hint", -- "hint", "block", or "center"
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

--- Start hint spinners on all painted regions
local function start_spinners(regions)
	stop_spinners()
	local spinner_module = config.spinner_type == "block" and "lg.block-spinner"
		or config.spinner_type == "center" and "lg.spinner"
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
--- @param opts? { prompt?: string }
function M.send(opts)
	opts = opts or {}
	local regions = paint.get_all()
	if #regions == 0 then
		vim.notify("lg: no painted regions", vim.log.levels.WARN)
		return
	end

	local function do_send(prompt, has_lsp)
		if not prompt or prompt == "" then
			return
		end

		if has_lsp then
			local lsp = require("lg.lsp")
			for _, r in ipairs(regions) do
				if vim.api.nvim_buf_is_valid(r.bufnr) then
					local info = lsp.gather(r.bufnr, r.start_line, r.end_line)
					if info ~= "" then
						window.add_result(
							"LSP info for "
								.. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(r.bufnr), ":~:.")
								.. ":\n"
								.. info
						)
					end
				end
			end
			window.refresh()
		end

		window.add_prompt(prompt)
		start_spinners(regions)
		session.send(prompt, regions, context.get_all(), function()
			vim.schedule(stop_spinners)
		end)
	end

	if opts.prompt then
		do_send(opts.prompt, false)
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
	window.refresh()
end
function M.clear_marks()
	diff.clear()
end

function M.clear_session()
	session.clear()
	window.clear_history()
end

function M.toggle_window()
	window.toggle()
end
function M.focus_chat()
	window.focus_input()
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
