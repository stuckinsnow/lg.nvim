--- Persistent visible terminal for approval-gated agent commands (`lg_run`).
--- Uses `snacks.terminal` when available, otherwise falls back to a reusable
--- bottom split with an interactive shell. Because the shell stays alive, there
--- is no "[Process exited 0]" banner; closing/hiding the window keeps the shell
--- running and the next `lg_run` reopens it (or respawns it if exited).

local M = {}

local MAX_OUTPUT_BYTES = 32 * 1024

local state = {
	snacks_term = nil,
	win = nil,
	buf = nil,
	job_id = nil,
}

local function win_valid(w)
	return w ~= nil and vim.api.nvim_win_is_valid(w)
end

local function buf_valid(b)
	return b ~= nil and vim.api.nvim_buf_is_valid(b)
end

local function job_alive(job_id)
	if not job_id or job_id <= 0 then
		return false
	end
	local ok, res = pcall(vim.fn.jobwait, { job_id }, 0)
	return ok and res and res[1] == -1
end

local function shell_quote(s)
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function scroll_to_bottom(win, buf)
	if not win_valid(win) or not buf_valid(buf) then
		return
	end
	if vim.api.nvim_get_current_win() == win then
		return
	end
	local lc = vim.api.nvim_buf_line_count(buf)
	pcall(vim.api.nvim_win_set_cursor, win, { lc, 0 })
end

--- Try to open or reuse a persistent `snacks.terminal` window.
--- Returns `win, buf, job_id` on success, or `nil` if snacks isn't available.
local function ensure_snacks_term()
	local ok, Snacks = pcall(require, "snacks")
	if not (ok and Snacks and Snacks.terminal and Snacks.terminal.get) then
		return nil
	end

	local term = state.snacks_term
	local alive = term and buf_valid(term.buf) and job_alive(vim.bo[term.buf].channel)
	if not alive then
		local ok_get, t = pcall(Snacks.terminal.get, nil, {
			cwd = vim.fn.getcwd(),
			win = { position = "bottom", height = 0.25 },
		})
		if not (ok_get and t and buf_valid(t.buf)) then
			return nil
		end
		term = t
		state.snacks_term = term
	else
		if not win_valid(term.win) then
			pcall(function() term:show() end)
		end
	end

	local job_id = vim.bo[term.buf].channel
	if not job_alive(job_id) then
		state.snacks_term = nil
		return nil
	end
	return term.win, term.buf, job_id
end

--- Open or reuse a persistent interactive shell in a bottom split.
local function ensure_builtin_term()
	local prev_win = vim.api.nvim_get_current_win()
	local alive = buf_valid(state.buf) and job_alive(state.job_id)

	if not alive then
		local buf = vim.api.nvim_create_buf(false, true)
		vim.bo[buf].bufhidden = "hide"
		vim.bo[buf].scrollback = 5000
		state.buf = buf
		state.job_id = nil
	end

	local win = state.win
	if win_valid(win) then
		vim.api.nvim_win_set_buf(win, state.buf)
	else
		local anchor = require("lg.util").find_editor_win() or prev_win
		vim.api.nvim_win_call(anchor, function()
			vim.cmd("belowright 12split")
			win = vim.api.nvim_get_current_win()
		end)
		vim.api.nvim_win_set_buf(win, state.buf)
		vim.wo[win].number = false
		vim.wo[win].relativenumber = false
		vim.wo[win].signcolumn = "no"
		vim.wo[win].winfixheight = true
		vim.wo[win].wrap = true
		state.win = win
	end

	if not alive then
		local shell = vim.o.shell ~= "" and vim.o.shell or (os.getenv("SHELL") or "sh")
		vim.api.nvim_win_call(win, function()
			state.job_id = vim.fn.jobstart({ shell }, {
				term = true,
				cwd = vim.fn.getcwd(),
			})
		end)
		vim.keymap.set("n", "q", function()
			if win_valid(state.win) then
				pcall(vim.api.nvim_win_close, state.win, true)
				state.win = nil
			end
		end, { buffer = state.buf, nowait = true, desc = "Hide lg terminal" })
	end

	return win, state.buf, state.job_id
end

--- Ensure a live persistent terminal is visible without stealing focus.
--- @return integer? win, integer? buf, integer? job_id
local function ensure_term()
	local prev_win = vim.api.nvim_get_current_win()
	local was_insert = vim.api.nvim_get_mode().mode:sub(1, 1) == "i"

	local win, buf, job_id = ensure_snacks_term()
	if not job_id then
		win, buf, job_id = ensure_builtin_term()
	end

	if win_valid(prev_win) and vim.api.nvim_get_current_win() ~= prev_win then
		pcall(vim.api.nvim_set_current_win, prev_win)
		if was_insert then
			vim.cmd("startinsert")
		end
	end

	scroll_to_bottom(win, buf)
	return win, buf, job_id
end

local function read_file(path)
	local f = io.open(path, "r")
	if not f then
		return ""
	end
	local content = f:read("*a") or ""
	f:close()
	return content
end

local function write_file(path, content)
	local f = io.open(path, "w")
	if not f then
		return false
	end
	f:write(content)
	f:close()
	return true
end

--- Run a shell command in the persistent visible terminal and invoke `on_done`
--- with `{ ok = true, exit_code = number, output = string, timed_out = boolean }`.
--- @param cmd string
--- @param timeout_seconds? number
--- @param on_done fun(res: table)
function M.run(cmd, timeout_seconds, on_done)
	local timeout = tonumber(timeout_seconds) or 60
	if timeout <= 0 then
		timeout = 60
	elseif timeout > 300 then
		timeout = 300
	end

	local win, buf, job_id = ensure_term()
	if not job_alive(job_id) then
		on_done({ ok = false, error = "failed to start terminal shell" })
		return
	end

	local base = vim.fn.tempname()
	local script_file = base .. ".sh"
	local fifo_file = base .. ".fifo"
	local out_file = base .. ".out"
	local done_file = base .. ".done"
	local pid_file = base .. ".pid"
	local cwd = vim.fn.getcwd()

	local script = table.concat({
		"#!/bin/sh",
		"echo $$ > " .. shell_quote(pid_file),
		"printf '\\033[1;36m$ %s\\033[0m\\n' " .. shell_quote(cmd),
		"rm -f " .. shell_quote(fifo_file),
		"mkfifo " .. shell_quote(fifo_file),
		"tee " .. shell_quote(out_file) .. " < " .. shell_quote(fifo_file) .. " &",
		"tee_pid=$!",
		"( cd " .. shell_quote(cwd) .. " && " .. cmd .. " ) > " .. shell_quote(fifo_file) .. " 2>&1",
		"rc=$?",
		'wait "$tee_pid"',
		"rm -f " .. shell_quote(fifo_file),
		'printf "%s\\n" "$rc" > ' .. shell_quote(done_file),
		"",
	}, "\n")

	if not write_file(script_file, script) then
		on_done({ ok = false, error = "failed to write command script" })
		return
	end

	-- Leading space avoids polluting bash/zsh history when ignorespace is set.
	vim.fn.chansend(job_id, " sh " .. shell_quote(script_file) .. "\n")

	local done = false
	local timed_out = false
	local poll_timer = vim.uv.new_timer()
	local timeout_timer = vim.uv.new_timer()

	local function cleanup_files()
		pcall(os.remove, script_file)
		pcall(os.remove, fifo_file)
		pcall(os.remove, out_file)
		pcall(os.remove, done_file)
		pcall(os.remove, pid_file)
	end

	local function stop_timers()
		for _, t in ipairs({ poll_timer, timeout_timer }) do
			if t then
				pcall(function()
					if not t:is_closing() then
						t:stop()
						t:close()
					end
				end)
			end
		end
	end

	local function finish(exit_code)
		if done then
			return
		end
		done = true
		stop_timers()
		local output = read_file(out_file):gsub("\r\n", "\n"):gsub("\n$", "")
		if #output > MAX_OUTPUT_BYTES then
			output = output:sub(1, MAX_OUTPUT_BYTES) .. "\n... (output truncated)"
		end
		cleanup_files()
		scroll_to_bottom(win, buf)
		on_done({
			ok = true,
			exit_code = exit_code,
			timed_out = timed_out,
			output = output,
		})
	end

	if poll_timer then
		poll_timer:start(50, 50, vim.schedule_wrap(function()
			if done then
				return
			end
			if vim.uv.fs_stat(done_file) then
				local rc = tonumber(vim.trim(read_file(done_file))) or 0
				finish(rc)
				return
			end
			if not job_alive(job_id) then
				finish(1)
				return
			end
			scroll_to_bottom(win, buf)
		end))
	end

	if timeout_timer then
		timeout_timer:start(timeout * 1000, 0, vim.schedule_wrap(function()
			if done then
				return
			end
			timed_out = true
			if job_alive(job_id) then
				pcall(vim.fn.chansend, job_id, "\x03")
			end
			local pid = tonumber(vim.trim(read_file(pid_file)))
			if pid then
				pcall(vim.uv.kill, pid, "sigterm")
			end
			-- Give the shell a moment to flush, then finish regardless.
			vim.defer_fn(function()
				finish(124)
			end, 150)
		end))
	end
end

--- Toggle the persistent lg terminal open/hidden.
function M.toggle()
	if state.snacks_term and buf_valid(state.snacks_term.buf) then
		pcall(function() state.snacks_term:toggle() end)
		return
	end
	if win_valid(state.win) then
		pcall(vim.api.nvim_win_close, state.win, true)
		state.win = nil
	else
		ensure_term()
		if win_valid(state.win) then
			pcall(vim.api.nvim_set_current_win, state.win)
		end
	end
end

function M.close()
	if state.snacks_term and win_valid(state.snacks_term.win) then
		pcall(function() state.snacks_term:hide() end)
	end
	if win_valid(state.win) then
		pcall(vim.api.nvim_win_close, state.win, true)
	end
	state.win = nil
end

return M
