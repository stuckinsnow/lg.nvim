local M = {}

function M.show()
	local session = require("lg.session.session")

	-- If commands are already available, the session is ready
	if #(session.available_commands()) > 0 then
		M._fetch()
		return
	end

	-- Session not ready. execute_command triggers connect(), and its callback
	-- fires after connect resolves. By then event handlers are set up, so we
	-- register our one-shot listener in the callback (after clear_handlers ran).
	session.execute_command("usage", function(resp)
		if resp.ok and resp.data then
			-- Worked on first try (unlikely on cold start but handle it)
			vim.schedule(function() M._handle_resp(resp) end)
			return
		end
		-- Command failed because agent wasn't ready yet. Listen for readiness.
		local client = require("lg.session.client")
		local unsub
		unsub = client.on("commands_available", function()
			if unsub then unsub() end
			vim.schedule(function() M._fetch() end)
		end)
	end)
end

function M._fetch()
	local session = require("lg.session.session")
	session.execute_command("usage", function(resp)
		vim.schedule(function() M._handle_resp(resp) end)
	end)
end

function M._handle_resp(resp)
	local data = resp.ok and resp.data
	if type(data) == "string" then
		local ok, parsed = pcall(vim.json.decode, data)
		if ok then data = parsed end
	end

	local info = data and data.data
	local breakdown = info and info.usageBreakdowns and info.usageBreakdowns[1]
	if not breakdown then
		vim.notify("No usage data available", vim.log.levels.WARN)
		return
	end

	M._render(info, breakdown)
end

function M._render(info, breakdown)
	local used = breakdown.used or 0
	local limit = breakdown.limit or 1
	local pct = (used / limit) * 100

	require("lg.kitty").set(pct)

	local bar_w = 20
	local filled = math.floor(bar_w * pct / 100)
	local remaining = limit - used

	local lines = {
		"## Kiro Credits",
		string.format("● Used: %.1f / %.0f", used, limit),
		"  " .. string.rep("█", filled) .. string.rep("░", bar_w - filled) .. string.format(" (%.1f%%)", pct),
		string.format("● Remaining: %.1f", remaining),
		string.format("● Plan: %s", info.planName or "?"),
		info.overagesEnabled and "● Overage: Permitted ✓" or "● Overage: Not Permitted ✗",
	}

	if info.billingCycleReset then
		local y, m, d = info.billingCycleReset:match("^(%d+)%-(%d+)%-(%d+)")
		local days_left = 0
		if y then
			days_left = math.floor(
				(os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d) }) - os.time()) / 86400
			)
		end
		local days_elapsed = 30 - days_left
		local daily_avg = days_elapsed > 0 and (used / days_elapsed) or 0
		local daily_budget = days_left > 0 and (remaining / days_left) or 0
		local rpct = math.max(0, math.min(((30 - days_left) / 30) * 100, 100))
		local rfilled = math.floor(bar_w * rpct / 100)
		table.insert(lines, "")
		table.insert(lines, string.format("● Daily avg: %.1f credits/day", daily_avg))
		table.insert(lines, string.format("● Budget: %.1f credits/day", daily_budget))
		table.insert(lines, "")
		table.insert(lines, string.format("> Resets: %s", info.billingCycleReset))
		table.insert(
			lines,
			"> " .. string.rep("█", rfilled) .. string.rep("░", bar_w - rfilled) .. string.format(" (%d days left)", days_left)
		)
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].filetype = "markdown"
	local w, h = 45, #lines + 1
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.floor((vim.o.lines - h) / 2),
		col = math.floor((vim.o.columns - w) / 2),
		width = w,
		height = h,
		style = "minimal",
		border = "rounded",
		title = " Kiro Usage ",
		title_pos = "center",
	})
	local function close()
		require("lg.kitty").clear()
		if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
	end
	vim.keymap.set("n", "q", close, { buffer = buf })
	vim.keymap.set("n", "<Esc>", close, { buffer = buf })
	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		once = true,
		callback = function() require("lg.kitty").clear() end,
	})
end

return M
