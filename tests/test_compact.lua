-- Verifies antigravity /compact behavior:
--   1. Queues behind an in-flight turn instead of clobbering M._on_done
--   2. Reports "Context compacted" on prompt_done
--   3. Does NOT report "Context compacted" on prompt_error
--
-- Run: nvim --headless -l tests/test_compact.lua

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

local client = require("lg.session.client")
local SID = "test-agy-session"
local prompts = {}

client.connect = function(cb) cb(true) end
client.is_connected = function() return true end
client.create_session = function(_, _, cb)
	cb({ ok = true, session_id = SID, models = { availableModels = { { modelId = "gemini-4-neon-medium" } } } })
end
client.send = function(_, cb)
	if cb then cb({ ok = true, active = 1 }) end
end
client.set_mode = function(_, _, cb)
	if cb then cb({ ok = true }) end
end
client.prompt = function(_, msgs)
	table.insert(prompts, msgs)
end
client.set_model = function() end
client.destroy_session = function() end

local status_msgs = {}
package.loaded["lg.ui.window"] = setmetatable({
	add_status = function(msg) table.insert(status_msgs, msg) end,
}, {
	__index = function() return function() end end,
})
package.loaded["lg.spinner.spinners"] = {
	start = function() return { stop = function() end } end,
}
vim.notify = function() end

local session = require("lg.session.session")
session.setup({ provider = "antigravity" })

-- 1. Compact called while a turn is in flight must queue, not clobber.
local turn_done = false
session.send_chat("hello", function() turn_done = true end)
vim.wait(50)
check("initial chat prompt sent", #prompts, 1)

session.compact()
vim.wait(50)
check("compact queued while busy", #prompts, 1)

client._dispatch({ type = "prompt_done", session_id = SID })
vim.wait(50)
check("in-flight turn callback still ran", turn_done, true)
check("queued compact flushed", #prompts, 2)
check("compact sent /compact text", prompts[2][1].text, "/compact")

-- 2. Successful compact reports Context compacted.
client._dispatch({ type = "prompt_done", session_id = SID })
vim.wait(50)
check("success status logged", status_msgs[#status_msgs], "Context compacted")
check("not busy after compact", session.is_busy(), false)

-- 3. Failed compact must NOT report Context compacted.
status_msgs = {}
session.compact()
vim.wait(50)
check("second compact sent", #prompts, 3)

client._dispatch({ type = "prompt_error", session_id = SID, error = "compact failed on server" })
vim.wait(50)
check("not busy after failed compact", session.is_busy(), false)
local saw_compacted = false
for _, m in ipairs(status_msgs) do
	if m == "Context compacted" then saw_compacted = true end
end
check("failed compact did not log Context compacted", saw_compacted, false)

print(failures == 0 and "\nall passed" or ("\n" .. failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
