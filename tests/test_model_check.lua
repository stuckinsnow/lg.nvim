-- Tests for lg.session.model-check
-- Run: nvim -l tests/test_model_check.lua

vim.opt.runtimepath:append(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h"))

local mc = require("lg.session.model-check")

local failures = 0
local function check(name, got, want)
	if got ~= want then
		failures = failures + 1
		print(("FAIL %s\n  got:  %s\n  want: %s"):format(name, vim.inspect(got), vim.inspect(want)))
	else
		print("ok   " .. name)
	end
end

-- Real kiro-cli 2.19.1 model list.
local ids = {
	"claude-opus-5",
	"claude-sonnet-5",
	"claude-opus-4.8",
	"gpt-5.6-sol",
	"claude-opus-4.6",
	"claude-sonnet-4.6",
	"claude-sonnet-4.5",
	"claude-haiku-4.5",
	"deepseek-3.2",
}
local session_models = {}
for _, id in ipairs(ids) do
	table.insert(session_models, { modelId = id })
end
session_models = { availableModels = session_models, currentModelId = "claude-opus-5" }

check("available_ids", #mc.available_ids(session_models), #ids)
check("available_ids handles nil", #mc.available_ids(nil), 0)

-- Punctuation-only rename: this is the id that broke in the wild.
check("closest: dash vs dot", mc.closest("claude-sonnet-4-6", ids), "claude-sonnet-4.6")
-- Retired version: falls forward to the newest in the same family, regardless of
-- the order the provider happens to list models in.
check("closest: retired minor", mc.closest("claude-sonnet-4.4", ids), "claude-sonnet-4.6")
check("closest: keeps family", mc.closest("claude-haiku-4.4", ids), "claude-haiku-4.5")
check("closest: unrelated id", mc.closest("llama-9", ids), nil)
check("closest: empty list", mc.closest("claude-sonnet-4-6", {}), nil)

-- Error explanation.
local err =
	"Encountered an error in the response stream: The model 'claude-sonnet-4-6' is not available. Please use '/model' to select a different model and try again. (request_id: abc)"
local msg = mc.explain_error(err, session_models, "kiro")
check("explain_error names the model", msg and msg:find("claude-sonnet-4-6", 1, true) ~= nil, true)
check("explain_error suggests a fix", msg and msg:find("claude-sonnet-4.6", 1, true) ~= nil, true)
check("explain_error ignores other errors", mc.explain_error("rate limit exceeded", session_models, "kiro"), nil)
check("explain_error ignores nil", mc.explain_error(nil, session_models, "kiro"), nil)
check(
	"explain_error handles 'does not exist'",
	mc.explain_error("Model 'bogus-model' does not exist", session_models, "kiro") ~= nil,
	true
)

-- validate_agents must never warn when the model list is unknown.
check("validate_agents: no models = no warning", #mc.validate_agents(nil, "kiro"), 0)
check("validate_agents: non-kiro provider", #mc.pinned_models("opencode"), 0)

-- Stale detection against a synthetic agent dir.
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/.kiro/agents", "p")
local function write_agent(name, model)
	local f = assert(io.open(tmp .. "/.kiro/agents/" .. name .. ".json", "w"))
	f:write(vim.json.encode({ name = name, model = model }))
	f:close()
end
write_agent("helper", "claude-sonnet-4-6") -- stale
write_agent("reviewer", "claude-sonnet-4.6") -- fine
write_agent("fullstack", "auto") -- alias, must be accepted
local f = assert(io.open(tmp .. "/.kiro/agents/broken.json", "w"))
f:write("{ not json")
f:close()

local cwd = vim.fn.getcwd()
vim.cmd.cd(tmp)
local pinned = mc.pinned_models("kiro")
local found = {}
for _, p in ipairs(pinned) do
	found[p.agent] = p.model
end
check("pinned_models reads helper", found.helper, "claude-sonnet-4-6")
check("pinned_models reads reviewer", found.reviewer, "claude-sonnet-4.6")
check("pinned_models skips malformed json", found.broken, nil)

local stale = mc.validate_agents(session_models, "kiro")
check("validate_agents finds one stale entry", #stale, 1)
check("validate_agents identifies the agent", stale[1] and stale[1].agent, "helper")
check("validate_agents suggests replacement", stale[1] and stale[1].suggestion, "claude-sonnet-4.6")
vim.cmd.cd(cwd)
vim.fn.delete(tmp, "rf")

print(failures == 0 and "\nall passed" or ("\n" .. failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
