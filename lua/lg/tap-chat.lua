--- Tap chat: embed kiro TUI in a terminal buffer with ACP event tapping

local M = {}

local state = {
	buf = nil,
	win = nil,
	job = nil,
	sock = nil,
}

local SOCK_PATH = "/dev/shm/lg-tap.sock"

--- Start listening for tap events from lg-tap binary
local function start_listener()
	if state.sock then
		return
	end

	vim.fn.delete(SOCK_PATH)
	local server = vim.uv.new_pipe(false)
	if not server then
		return
	end

	server:bind(SOCK_PATH)
	server:listen(8, function(err)
		if err then
			return
		end
		local client = vim.uv.new_pipe(false)
		if not client then
			return
		end
		server:accept(client)

		local buf = ""
		client:read_start(function(read_err, data)
			if read_err or not data then
				pcall(function()
					client:close()
				end)
				return
			end
			buf = buf .. data
			while true do
				local nl = buf:find("\n")
				if not nl then
					break
				end
				local line = buf:sub(1, nl - 1)
				buf = buf:sub(nl + 1)
				if line ~= "" then
					vim.schedule(function()
						M._on_event(line)
					end)
				end
			end
		end)
	end)

	state.sock = server
end

--- Handle a tap event
function M._on_event(raw)
	local ok, msg = pcall(vim.json.decode, raw)
	if not ok then
		return
	end

	local method = msg and msg.method

	if method == "session/update" then
		local params = msg.params
		local update = params and params.update
		if type(update) == "string" then
			ok, update = pcall(vim.json.decode, update)
			if not ok then
				return
			end
		end
		if not update then
			return
		end

		if update.sessionUpdate == "tool_call" and update.kind == "edit" then
			local content = update.content
			if not content or #content == 0 then
				return
			end

			-- Clear previous preview before showing new one
			local hunk = require("lg.ui.hunk")
			hunk.reject_all_silent()

			for _, diff_entry in ipairs(content) do
				if diff_entry.type == "diff" and diff_entry.path then
					hunk.propose_edit(diff_entry.path, diff_entry.oldText, diff_entry.newText, { no_focus = true })
				end
			end
		elseif update.sessionUpdate == "tool_call_update" and update.kind == "edit" then
			local hunk = require("lg.ui.hunk")
			if update.status == "completed" then
				hunk.accept_all()
			end
		elseif update.sessionUpdate == "tool_call" then
			local title = update.title or "?"
			vim.notify("lg-tap: " .. title, vim.log.levels.INFO)
		end
	elseif msg.result and msg.result.stopReason then
		-- Turn ended: clear any remaining diff preview (handles rejections)
		local hunk = require("lg.ui.hunk")
		if #hunk.pending() > 0 then
			hunk.reject_all_silent()
		end
	end
end

function M.open()
	if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
		-- Already open, just focus
		if state.win and vim.api.nvim_win_is_valid(state.win) then
			vim.api.nvim_set_current_win(state.win)
			vim.cmd.startinsert()
		end
		return
	end

	start_listener()

	local plugin_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
	local tap_bin = plugin_dir .. "/tap/lg-tap"

	state.buf = vim.api.nvim_create_buf(false, true)
	vim.cmd("vsplit")
	state.win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(state.win, state.buf)

	state.job = vim.fn.jobstart({
		vim.fn.expand("~/.local/share/kiro-cli/bun"),
		vim.fn.expand("~/.local/share/kiro-cli/tui.js"),
		"chat",
		"--tui",
	}, {
		term = true,
		cwd = vim.fn.getcwd(),
		env = {
			KIRO_AGENT_PATH = tap_bin,
			REAL_KIRO_AGENT = "kiro-cli",
			TERM = "xterm-256color",
			COLORFGBG = "15;0",
			NO_COLOR = "1",
		},
		on_exit = function()
			vim.schedule(function()
				M.close()
			end)
		end,
	})

	vim.wo[state.win].number = false
	vim.wo[state.win].relativenumber = false
	vim.wo[state.win].signcolumn = "no"
	vim.wo[state.win].winfixwidth = true
	vim.wo[state.win].foldcolumn = "1"
	vim.api.nvim_win_set_width(state.win, 60)

	-- Double-escape exits terminal mode; single escape goes to TUI
	vim.keymap.set("t", "<Esc><Esc>", [[<C-\><C-n>]], { buffer = state.buf, desc = "Exit terminal mode" })
	vim.keymap.set("t", "<C-w>", [[<C-\><C-n><C-w>]], { buffer = state.buf, desc = "Window commands" })
	vim.keymap.set("n", "<leader>aq", function()
		M.close()
	end, { buffer = state.buf, desc = "Kill tap chat" })

	vim.cmd.startinsert()
end

function M.close()
	if state.job then
		pcall(vim.fn.jobstop, state.job)
		state.job = nil
	end
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		vim.api.nvim_win_close(state.win, true)
		state.win = nil
	end
	if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
		vim.api.nvim_buf_delete(state.buf, { force = true })
		state.buf = nil
	end
	if state.sock then
		pcall(function()
			state.sock:close()
		end)
		state.sock = nil
		vim.fn.delete(SOCK_PATH)
	end
end

function M.toggle()
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		-- Hide: just close the window, keep job alive
		vim.api.nvim_win_close(state.win, true)
		state.win = nil
	elseif state.buf and vim.api.nvim_buf_is_valid(state.buf) then
		-- Show: reopen window with existing buffer
		vim.cmd("vsplit")
		state.win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(state.win, state.buf)
		vim.wo[state.win].number = false
		vim.wo[state.win].relativenumber = false
		vim.wo[state.win].signcolumn = "no"
		vim.wo[state.win].winfixwidth = true
		vim.api.nvim_win_set_width(state.win, 60)
		vim.cmd.startinsert()
	else
		-- First open
		M.open()
	end
end

function M.is_active()
	return state.job ~= nil and state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

--- Send a keystroke to the kiro TUI terminal
function M._send(keys)
	if state.job then
		vim.api.nvim_chan_send(state.job, keys)
	end
end

return M
