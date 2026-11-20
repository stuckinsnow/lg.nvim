-- Tests for lg.usage (Antigravity usage formatting and window rendering)
-- Run: nvim -l tests/test_usage.lua

vim.opt.runtimepath:append(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h"))

-- Stub kitty so headless tests don't write escape sequences to stdout.
local kitty_pct = nil
package.loaded["lg.kitty"] = {
	set = function(p) kitty_pct = p end,
	clear = function() kitty_pct = nil end,
}

local usage = require("lg.usage")

local failures = 0
local function check(name, got, want)
	if got ~= want then
		failures = failures + 1
		print(("FAIL %s\n  got:  %s\n  want: %s"):format(name, vim.inspect(got), vim.inspect(want)))
	else
		print("ok   " .. name)
	end
end

local sample_json = [[
{"conversation_id":"","status":"SUCCESS","response":"","command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.44679200649261475,"reset_time":"2026-11-26T13:06:02Z"},{"id":"gemini-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":0.7406343221664429,"reset_time":"2026-11-21T00:43:27Z"}]},{"name":"Claude and GPT models","buckets":[{"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.005456400103867054,"reset_time":"2026-11-26T13:04:47Z"},{"id":"3p-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":1,"reset_time":"2026-11-21T04:37:57Z"}]},{"name":"Gemini 4 Argon","buckets":[{"id":"gemini-argon-wtu-weekly","name":"Gemini 4 Argon Weekly Limit","window":"weekly","remaining_fraction":0.9801817536354065,"reset_time":"2026-11-26T19:44:29Z"}]}]}}}
]]

local parsed = vim.json.decode(sample_json)
local groups = parsed.command.data.groups

-- 2026-11-20T23:37:00Z
local utc_ref = os.time({ year = 2026, month = 11, day = 20, hour = 23, min = 37, sec = 0, isdst = false })
local tz_diff = os.difftime(os.time(os.date("*t", utc_ref)), os.time(os.date("!*t", utc_ref)))
local now_unix = math.floor(utc_ref + tz_diff)

local lines, used_pct = usage._format_antigravity(groups, now_unix)
local text = table.concat(lines, "\n")

check("contains Gemini Models heading", text:find("## Gemini Models", 1, true) ~= nil, true)
check("contains Claude and GPT models heading", text:find("## Claude and GPT models", 1, true) ~= nil, true)
check("contains Gemini 4 Argon heading", text:find("## Gemini 4 Argon", 1, true) ~= nil, true)
check("gemini weekly percentage", text:find("(44.7%)", 1, true) ~= nil, true)
check("gemini 5h percentage", text:find("(74.1%)", 1, true) ~= nil, true)
check("claude weekly percentage", text:find("(0.5%)", 1, true) ~= nil, true)
check("claude 5h percentage", text:find("(100.0%)", 1, true) ~= nil, true)
check("argon weekly percentage", text:find("(98.0%)", 1, true) ~= nil, true)
check("gemini weekly reset", text:find("> Resets in 5d 13h (2026-11-26 13:06Z)", 1, true) ~= nil, true)
check("gemini 5h reset", text:find("> Resets in 1h 6m (2026-11-21 00:43Z)", 1, true) ~= nil, true)
check("primary used pct", math.floor(used_pct + 0.5), 55)

-- Verify _handle_antigravity_resp opens the floating window and sets kitty progress.
usage._handle_antigravity_resp(sample_json)
check("kitty progress set", math.floor(kitty_pct + 0.5), 55)
local win = vim.api.nvim_get_current_win()
local cfg = vim.api.nvim_win_get_config(win)
check("floating window opened", cfg.relative, "editor")
check("buffer filetype is markdown", vim.bo[vim.api.nvim_win_get_buf(win)].filetype, "markdown")
vim.api.nvim_win_close(win, true)

if failures > 0 then
	print(("\n%d test(s) failed"):format(failures))
	os.exit(1)
end
print("\nAll usage tests passed!")
