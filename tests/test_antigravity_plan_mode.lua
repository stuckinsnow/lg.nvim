-- Verifies that Antigravity's native "plan" mode stays active across
-- agent_switched events and send_chat turns, and exits cleanly to "default".
--
-- Run: nvim --headless -u NONE -l tests/test_antigravity_plan_mode.lua

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

-- Isolate persisted state so local user config does not override provider.
local orig_stdpath = vim.fn.stdpath
vim.fn.stdpath = function(what)
	if what == "data" then
		return "/tmp/lg-test-antigravity-plan"
	end
	return orig_stdpath(what)
end

-- ── Stub the transport ─────────────────────────────────────────────
local client = require("lg.session.client")
local SID = "test-agy-session"
local modes_set, prompts, statuses = {}, {}, {}

client.connect = function(cb)
	cb(true)
end
client.is_connected = function()
	return true
end
client.create_session = function(_, _, cb)
	cb({ ok = true, session_id = SID, models = { availableModels = { { modelId = "auto" } } } })
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

package.loaded["lg.ui.window"] = setmetatable({
	add_status = function(msg)
		table.insert(statuses, msg)
	end,
}, {
	__index = function()
		return function() end
	end,
})
vim.notify = function() end

local session = require("lg.session.session")
session.setup({ provider = "antigravity" })

-- ── Toggle planner on ──────────────────────────────────────────────
local enable_ok = nil
session.set_planner(true, function(ok)
	enable_ok = ok
end)
vim.wait(50)

check("set_planner(true) succeeded", enable_ok, true)
check("set_planner(true) sent plan mode", modes_set[#modes_set], "plan")
check("planner active before agent_switched", session.is_planner_active(), true)

client._dispatch({
	type = "agent_switched",
	session_id = SID,
	data = { agentName = "plan", previousAgentName = "default" },
})
vim.wait(50)

check("planner stays active on agent_switched(plan)", session.is_planner_active(), true)
check("status shows plan mode", statuses[#statuses], "▶ plan mode (default → plan)")

-- ── send_chat while in plan mode ───────────────────────────────────
local chat_done = false
session.send_chat("are you a plan agent?", function()
	chat_done = true
end)
vim.wait(50)

check("send_chat stayed in plan mode", modes_set[#modes_set], "plan")
check("chat prompt sent", #prompts, 1)

client._dispatch({ type = "prompt_done", session_id = SID })
vim.wait(50)

check("chat turn completed", chat_done, true)
check("mode remained plan after turn", modes_set[#modes_set], "plan")
check("planner still active after turn", session.is_planner_active(), true)

-- ── Toggle planner off ─────────────────────────────────────────────
local disable_ok = nil
session.set_planner(false, function(ok)
	disable_ok = ok
end)
vim.wait(50)

check("set_planner(false) succeeded", disable_ok, true)
check("set_planner(false) sent default mode", modes_set[#modes_set], "default")

client._dispatch({
	type = "agent_switched",
	session_id = SID,
	data = { agentName = "default", previousAgentName = "plan" },
})
vim.wait(50)

check("planner inactive after agent_switched(default)", session.is_planner_active(), false)
check("exit-plan-mode turn sent", #prompts, 2)

client._dispatch({ type = "prompt_done", session_id = SID })
vim.wait(50)

print(failures == 0 and "\nall passed" or ("\n" .. failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
