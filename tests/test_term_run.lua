-- Headless test for lua/lg/ui/term.lua (persistent shell terminal)
-- Run: nvim --headless -u NONE --cmd "set rtp+=." -l tests/test_term_run.lua

-- Use /bin/sh in headless test so user rc files don't interfere
vim.o.shell = "/bin/sh"

local term = require("lg.ui.term")

local function wait_for(pred, timeout_ms)
	local ok = vim.wait(timeout_ms or 5000, pred, 20)
	if not ok then
		error("timed out waiting for condition")
	end
end

-- 1. Successful command opens terminal split, keeps focus on original win, captures output
local orig_win = vim.api.nvim_get_current_win()
local res1 = nil
term.run("echo hello-from-term", 10, function(r)
	res1 = r
end)
wait_for(function() return res1 ~= nil end)

assert(res1.ok == true, "expected ok=true")
assert(res1.exit_code == 0, "expected exit_code=0, got " .. tostring(res1.exit_code))
assert(res1.output == "hello-from-term", "expected exact output 'hello-from-term', got: " .. vim.inspect(res1.output))
assert(vim.api.nvim_get_current_win() == orig_win, "expected focus to remain on original window")
assert(#vim.api.nvim_tabpage_list_wins(0) == 2, "expected terminal split to remain open")

-- 2. Closing the window hides it; next command reopens it reusing the live shell
term.close()
assert(#vim.api.nvim_tabpage_list_wins(0) == 1, "expected term.close() to hide split")

local res2 = nil
term.run("echo err-line; exit 7", 10, function(r)
	res2 = r
end)
wait_for(function() return res2 ~= nil end)

assert(res2.ok == true, "expected ok=true")
assert(res2.exit_code == 7, "expected exit_code=7, got " .. tostring(res2.exit_code))
assert(res2.output == "err-line", "expected output 'err-line', got: " .. vim.inspect(res2.output))
assert(#vim.api.nvim_tabpage_list_wins(0) == 2, "expected terminal split to reopen")

-- 3. Timeout stops the command and sets timed_out=true
local res3 = nil
term.run("sleep 10", 1, function(r)
	res3 = r
end)
wait_for(function() return res3 ~= nil end, 5000)
assert(res3.timed_out == true, "expected timed_out=true, got " .. vim.inspect(res3))

term.close()
assert(#vim.api.nvim_tabpage_list_wins(0) == 1, "expected term.close() to close split")

print("ALL TERM TESTS PASSED")
