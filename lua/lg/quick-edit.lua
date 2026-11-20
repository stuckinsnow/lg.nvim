--- Quick-edit: visual select → prompt → edit via main session with isolated region

local session = require("lg.session.session")
local spinners = require("lg.spinner.spinners")

local M = {}

local paint_ns = vim.api.nvim_create_namespace("lg.ui.paint")

local function highlight(bufnr, start_line, end_line)
	local signs = require("lg.ui.signs")
	vim.hl.range(
		bufnr,
		paint_ns,
		"LgPaintLine",
		{ start_line - 1, 0 },
		{ end_line - 1, 0 },
		{ regtype = "V", inclusive = true, priority = 110 }
	)
	for row = start_line - 1, end_line - 1 do
		vim.api.nvim_buf_set_extmark(bufnr, paint_ns, row, 0, {
			sign_text = signs.bracket(row, start_line, end_line),
			sign_hl_group = "LgPaintSign",
			priority = 110,
		})
	end
end

local function clear_highlight(bufnr, start_line, end_line)
	local marks = vim.api.nvim_buf_get_extmarks(bufnr, paint_ns, { start_line - 1, 0 }, { end_line - 1, -1 }, {})
	for _, mark in ipairs(marks) do
		vim.api.nvim_buf_del_extmark(bufnr, paint_ns, mark[1])
	end
end

function M.quick_edit()
	local buf = vim.api.nvim_get_current_buf()
	local start_line = vim.fn.getpos("'<")[2]
	local end_line = vim.fn.getpos("'>")[2]
	local file = vim.api.nvim_buf_get_name(buf)
	local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)

	highlight(buf, start_line, end_line)

	local region = {
		bufnr = buf,
		file = file,
		start_line = start_line,
		end_line = end_line,
		lines = lines,
	}

	local provider = session.current_provider() or "?"
	local model = session.current_model()
	local function info(model_id)
		return "oneshot │ " .. provider .. "/" .. (model_id or "default")
	end
	local function open_prompt(model_id)
		require("lg.ui.prompt").open(function(prompt, flags)
			if not prompt or prompt == "" then
				clear_highlight(buf, start_line, end_line)
				return
			end

			if flags.has_lsp then
				local lsp_info = require("lg.tools.lsp").gather(buf, start_line, end_line)
				if lsp_info ~= "" then prompt = prompt .. "\n\nLSP Information:\n" .. lsp_info end
			end

			local spin = spinners.start({ region })
			if flags.has_suggest or flags.has_hint or flags.has_help then
				local send_mod = require("lg.session.send")
				local target_win = vim.api.nvim_get_current_win()
				local before_keys = send_mod.snapshot_diag_keys()
				local sub_fn, title
				if flags.has_suggest then
					prompt = prompt:gsub("@SUGGEST%s*", "")
					sub_fn = session.send_suggest_subagent
					title = "lg suggestions"
				elseif flags.has_hint then
					prompt = prompt:gsub("@REVIEW%s*", "")
					sub_fn = session.send_hint_subagent
					title = "lg hints"
				else
					prompt = prompt:gsub("@HELP%s*", "")
					sub_fn = session.send_help_subagent
					title = "lg help"
				end
				sub_fn(prompt, { region }, {}, function()
					vim.defer_fn(function()
						spin:stop()
						clear_highlight(buf, start_line, end_line)
						send_mod.annotations_to_loclist(before_keys, target_win, title)
					end, 500)
				end)
				return
			end
			session.send_oneshot(prompt, { region }, {}, function()
				vim.schedule(function()
					spin:stop()
					clear_highlight(buf, start_line, end_line)
				end)
			end)
		end, function()
			clear_highlight(buf, start_line, end_line)
		end, info(model_id))
	end

	if model then
		open_prompt(model)
	else
		session.fetch_model(vim.schedule_wrap(function(model_id)
			open_prompt(model_id or "default")
		end))
	end
end

return M
