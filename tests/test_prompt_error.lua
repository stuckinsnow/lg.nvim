-- Verifies that a failed turn (prompt_error) does not wedge the session:
-- the agent mode must be restored, the busy flag cleared, and any queued
-- prompt must still fire. Regression test for the hang seen when an agent
-- pinned an unavailable model.
--
-- Run: nvim --headless -l tests/test_prompt_error.lua

vim.opt.runtimepath:append(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h"))

local failures = 0
local function check(name, got, want)
	if got ~= want then
		failures = failures + 1
		print(("FAIL %s\n  got:  %s\n  want: %s"):format(name, vim.inspect(got), vim.inspect(want)))
	else
		print("ok   " .. name)
	end
end

-- ── Stub the transport ─────────────────────────────────────────────
local client = require("lg.session.client")
local SID = "test-session"
local modes_set, prompts = {}, {}

client.connect = function(cb)
	cb(true)
end
client.is_connected = function()
	return true
end
client.create_session = function(_, _, cb)
	cb({ ok = true, session_id = SID, models = { availableModels = { { modelId = "claude-sonnet-4.6" } } } })
end
client.send = function(_, cb)
	if cb then
		cb({ ok = true, active = 1 })
	end
end
client.set_mode = function(_, mode_id, cb)
	table.insert(modes_set, mode_id)
	if cb then
		cb({ ok = true })
	end
end
client.prompt = function(_, msgs)
	table.insert(prompts, msgs)
end
client.set_model = function() end
client.destroy_session = function() end

-- Keep UI and notifications out of the way.
package.loaded["lg.ui.window"] = setmetatable({}, {
	__index = function()
		return function() end
	end,
})
vim.notify = function() end

local session = require("lg.session.session")
session.setup({ provider = "kiro" })

-- ── First turn: a mode send that will fail ─────────────────────────
local first_done = false
session.send_mode({ mode_id = "helper" }, "review this", {}, {}, function()
	first_done = true
end)
vim.wait(50)

check("switched into helper mode", modes_set[#modes_set], "helper")
check("first prompt sent", #prompts, 1)

-- ── A second send arrives while the first is still in flight ───────
local second_done = false
session.send("fix it", {}, {}, function()
	second_done = true
end)
vim.wait(50)
check("second send is queued, not sent", #prompts, 1)

-- ── The first turn fails ───────────────────────────────────────────
client._dispatch({
	type = "prompt_error",
	session_id = SID,
	error = "Encountered an error in the response stream: The model 'claude-sonnet-4-6' is not available.",
})
vim.wait(100)

check("mode restored to lg", modes_set[#modes_set], "lg")
check("completion callback ran", first_done, true)
check("queued prompt was flushed", #prompts, 2)

-- ── And the session still works afterwards ─────────────────────────
client._dispatch({ type = "prompt_done", session_id = SID })
vim.wait(50)
check("queued turn completes", second_done, true)

local third = false
session.send("another one", {}, {}, function()
	third = true
end)
vim.wait(50)
check("not stuck busy: next send goes straight out", #prompts, 3)
client._dispatch({ type = "prompt_done", session_id = SID })
vim.wait(50)
check("third turn completes", third, true)

print(failures == 0 and "\nall passed" or ("\n" .. failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
