local M = {}

local BAR_W = 20

local function bar(pct)
	local clamped = math.max(0, math.min(100, pct))
	local filled = math.floor(BAR_W * clamped / 100)
	return string.rep("█", filled) .. string.rep("░", BAR_W - filled)
end

local function open_window(lines, title)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].filetype = "markdown"

	local max_w = 45
	for _, line in ipairs(lines) do
		local lw = vim.fn.strdisplaywidth(line) + 4
		if lw > max_w then
			max_w = lw
		end
	end
	local w = math.min(max_w, math.max(20, vim.o.columns - 4))
	local h = math.min(#lines + 1, math.max(5, vim.o.lines - 4))

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.floor((vim.o.lines - h) / 2),
		col = math.floor((vim.o.columns - w) / 2),
		width = w,
		height = h,
		style = "minimal",
		border = "rounded",
		title = " " .. title .. " ",
		title_pos = "center",
	})
	local function close()
		require("lg.kitty").clear()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end
	vim.keymap.set("n", "q", close, { buffer = buf })
	vim.keymap.set("n", "<Esc>", close, { buffer = buf })
	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		once = true,
		callback = function()
			require("lg.kitty").clear()
		end,
	})
	return buf, win
end

--- Compute seconds until an ISO-8601 UTC timestamp (YYYY-MM-DDTHH:MM:SSZ).
--- @param iso string
--- @param now? integer unix timestamp (defaults to os.time())
--- @return integer? seconds remaining
function M._seconds_until_utc(iso, now)
	if type(iso) ~= "string" then
		return nil
	end
	local y, m, d, H, Mn, S = iso:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)Z")
	if not y then
		return nil
	end
	local utc_now = os.date("!*t", now or os.time())
	utc_now.isdst = false
	local target = {
		year = tonumber(y),
		month = tonumber(m),
		day = tonumber(d),
		hour = tonumber(H),
		min = tonumber(Mn),
		sec = tonumber(S),
		isdst = false,
	}
	return math.floor(os.difftime(os.time(target), os.time(utc_now)))
end

local function format_reset(iso, now)
	local y, m, d, H, Mn = (iso or ""):match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+)")
	local short = y and string.format("%s-%s-%s %s:%sZ", y, m, d, H, Mn) or iso
	local secs = M._seconds_until_utc(iso, now)
	if not secs then
		return short
	end
	if secs <= 0 then
		return string.format("now (%s)", short)
	end
	local days = math.floor(secs / 86400)
	local hours = math.floor((secs % 86400) / 3600)
	local mins = math.floor((secs % 3600) / 60)
	local rel
	if days > 0 then
		rel = string.format("%dd %dh", days, hours)
	elseif hours > 0 then
		rel = string.format("%dh %dm", hours, mins)
	else
		rel = string.format("%dm", mins)
	end
	return string.format("in %s (%s)", rel, short)
end

--- Format Antigravity `/usage` JSON data into markdown lines.
--- @param groups table[]
--- @param now? integer optional unix timestamp for deterministic formatting
--- @return string[] lines, number? primary_used_pct
function M._format_antigravity(groups, now)
	local lines = {}
	local primary_used_pct = nil

	for gi, group in ipairs(groups) do
		if gi > 1 then
			table.insert(lines, "")
		end
		table.insert(lines, "## " .. (group.name or "Usage"))
		for _, bucket in ipairs(group.buckets or {}) do
			local frac = tonumber(bucket.remaining_fraction)
			local pct = frac and (frac * 100) or 0
			if primary_used_pct == nil and frac then
				primary_used_pct = (1 - frac) * 100
			end
			table.insert(lines, "● " .. (bucket.name or bucket.window or "Limit"))
			table.insert(lines, string.format("  %s (%.1f%%)", bar(pct), pct))
			if bucket.reset_time and bucket.reset_time ~= "" then
				table.insert(lines, "> Resets " .. format_reset(bucket.reset_time, now))
			end
		end
	end

	return lines, primary_used_pct
end

function M._handle_antigravity_resp(stdout)
	local ok, parsed = pcall(vim.json.decode, stdout or "")
	local groups = ok and parsed and parsed.command and parsed.command.data and parsed.command.data.groups
	if type(groups) ~= "table" or #groups == 0 then
		vim.notify("No usage data available", vim.log.levels.WARN)
		return
	end

	local lines, used_pct = M._format_antigravity(groups)
	if used_pct then
		require("lg.kitty").set(used_pct)
	end
	open_window(lines, "Antigravity Usage")
end

function M.show()
	local session = require("lg.session.session")
	if session.current_provider() == "antigravity" then
		vim.system({ "agy", "--print", "/usage", "--output-format", "json" }, { text = true }, function(obj)
			vim.schedule(function()
				if obj.code ~= 0 or not obj.stdout or obj.stdout == "" then
					vim.notify("Failed to fetch Antigravity usage", vim.log.levels.WARN)
					return
				end
				M._handle_antigravity_resp(obj.stdout)
			end)
		end)
		return
	end

	session.rpc("_kiro/account/getUsage", M._handle_resp)
end

function M._handle_resp(resp)
	local data = resp.ok and resp.data
	if type(data) == "string" then
		local ok, parsed = pcall(vim.json.decode, data)
		if ok then
			data = parsed
		end
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

	local remaining = limit - used

	local lines = {
		"## Kiro Credits",
		string.format("● Used: %.1f / %.0f", used, limit),
		"  " .. bar(pct) .. string.format(" (%.1f%%)", pct),
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
		table.insert(lines, "")
		table.insert(lines, string.format("● Daily avg: %.1f credits/day", daily_avg))
		table.insert(lines, string.format("● Budget: %.1f credits/day", daily_budget))
		table.insert(lines, "")
		table.insert(lines, string.format("> Resets: %s", info.billingCycleReset))
		table.insert(lines, "> " .. bar(rpct) .. string.format(" (%d days left)", days_left))
	end

	open_window(lines, "Kiro Usage")
end

return M
