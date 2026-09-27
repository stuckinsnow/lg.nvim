-- Verifies that approval prompts are shown one at a time. Parallel tool calls
-- used to open several vim.ui.select pickers at once; the picker replaced the
-- earlier ones, their callbacks never fired, and the agent hung waiting.
--
-- Run: nvim --headless -l tests/test_approval_queue.lua

vim.opt.runtimepath:append(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h"))

local failures = 0
local function check(name, got, want)
	if not vim.deep_equal(got, want) then
		failures = failures + 1
		print(("FAIL %s\n  got:  %s\n  want: %s"):format(name, vim.inspect(got), vim.inspect(want)))
	else
		print("ok   " .. name)
	end
end

-- Fake picker that, like fzf-lua, supports a single open instance: opening a
-- new one while another is open drops the old callback.
local open, max_open, prompts = nil, 0, {}
vim.ui.select = function(_, opts, on_choice)
	open = { cb = on_choice }
	max_open = math.max(max_open, 1)
	table.insert(prompts, opts.prompt)
end
local function answer(choice)
	local cur = open
	open = nil
	cur.cb(choice, choice == "Allow" and 1 or 2)
end
local function flush()
	vim.wait(20, function() return false end)
end

local approval = require("lg.ui.approval")
local OPTS = {
	{ optionId = "allow_once", kind = "allow_once" },
	{ optionId = "allow_always", kind = "allow_always" },
	{ optionId = "reject_once", kind = "reject_once" },
}

local responses = {}
approval.permission("Running: @devlens/get_component_tree", OPTS, function(oid, allowed)
	table.insert(responses, { "tree", oid, allowed })
end)
approval.permission("Running: @devlens/get_console_logs", OPTS, function(oid, allowed)
	table.insert(responses, { "logs", oid, allowed })
end)
flush()

check("only first prompt shown", #prompts, 1)
check("first prompt shows queue count", prompts[1], "Running: @devlens/get_component_tree? (+1 queued)")
check("pending counts both", approval.pending(), 2)

answer("Allow")
flush()
check("second prompt shown after first answered", #prompts, 2)
check("second prompt mentions nothing queued", prompts[2], "Running: @devlens/get_console_logs?")

answer("Reject")
flush()
check("both callbacks fired in order", responses, {
	{ "tree", "allow_once", true },
	{ "logs", "reject_once", false },
})
check("queue drained", approval.pending(), 0)

-- Cancelling (nil choice) still advances the queue.
local got = {}
approval.select({ "a" }, { prompt = "one" }, function(c) table.insert(got, c or "nil") end)
approval.select({ "b" }, { prompt = "two" }, function(c) table.insert(got, c or "nil") end)
flush()
answer(nil)
flush()
answer("b")
flush()
check("cancel advances queue", got, { "nil", "b" })

-- A throwing callback doesn't wedge the queue.
approval.select({ "x" }, { prompt = "boom" }, function() error("boom") end)
approval.select({ "y" }, { prompt = "after" }, function(c) table.insert(got, c) end)
flush()
answer("x")
flush()
answer("y")
flush()
check("error in callback doesn't block next", got[#got], "y")

print(failures == 0 and "\nall passed" or ("\n" .. failures .. " failure(s)"))
os.exit(failures == 0 and 0 or 1)
