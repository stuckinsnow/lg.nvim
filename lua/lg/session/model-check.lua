--- Model availability checks.
---
--- Agent config files pin a model by id (e.g. `"model": "claude-sonnet-4.6"`).
--- Providers retire and rename models, so a pinned id can silently go stale —
--- the agent then fails mid-turn with an opaque "Internal error". This module
--- turns that into an actionable warning, both proactively (on session create)
--- and reactively (when a prompt fails).

local M = {}

--- @param session_models table? models info from create_session
--- @return string[] available model ids
function M.available_ids(session_models)
	local ids = {}
	for _, m in ipairs(session_models and session_models.availableModels or {}) do
		if m.modelId then
			ids[#ids + 1] = m.modelId
		end
	end
	return ids
end

--- Normalised form used for fuzzy matching: lowercase, digits/letters only.
--- `claude-sonnet-4-6` and `claude-sonnet-4.6` both become `claudesonnet46`.
--- @param id string
--- @return string
local function normalise(id)
	return (id:lower():gsub("[^%w]", ""))
end

--- Version numbers in an id, e.g. `claude-sonnet-4.6` → { 4, 6 }.
--- @param id string
--- @return integer[]
local function version(id)
	local nums = {}
	for n in id:gmatch("%d+") do
		nums[#nums + 1] = tonumber(n)
	end
	return nums
end

--- True when `a` is a newer version than `b`.
--- @param a string
--- @param b string?
--- @return boolean
local function newer(a, b)
	if not b then
		return true
	end
	local va, vb = version(a), version(b)
	for i = 1, math.max(#va, #vb) do
		local x, y = va[i] or -1, vb[i] or -1
		if x ~= y then
			return x > y
		end
	end
	return false
end

--- Best guess at what a stale model id was meant to be.
--- @param wanted string
--- @param ids string[]
--- @return string? suggestion
function M.closest(wanted, ids)
	local target = normalise(wanted)
	-- Exact match once punctuation is ignored (the common rename case).
	for _, id in ipairs(ids) do
		if normalise(id) == target then
			return id
		end
	end
	-- Otherwise the candidate sharing the longest prefix, e.g. a bumped version.
	-- Ties go to the newest version, so the result never depends on list order.
	local best, best_len = nil, 0
	for _, id in ipairs(ids) do
		local cand = normalise(id)
		local len = 0
		while len < #target and len < #cand and target:byte(len + 1) == cand:byte(len + 1) do
			len = len + 1
		end
		-- Require a meaningful overlap so unrelated families never match.
		if len >= 6 and (len > best_len or (len == best_len and newer(id, best))) then
			best, best_len = id, len
		end
	end
	return best
end

--- Directories that may hold kiro agent definitions, most specific first.
--- @return string[]
local function kiro_agent_dirs()
	return {
		vim.fn.getcwd() .. "/.kiro/agents",
		vim.fn.expand("~/.kiro/agents"),
	}
end

--- Read the model pinned by each agent config.
--- Only kiro is supported: opencode agents inherit the session model.
--- @param provider string
--- @return { agent: string, model: string, path: string }[]
function M.pinned_models(provider)
	if provider ~= "kiro" then
		return {}
	end
	local out = {}
	local seen = {}
	for _, dir in ipairs(kiro_agent_dirs()) do
		for _, path in ipairs(vim.fn.glob(dir .. "/*.json", false, true)) do
			local name = vim.fn.fnamemodify(path, ":t:r")
			if not seen[name] then
				seen[name] = true
				local f = io.open(path, "r")
				if f then
					local ok, cfg = pcall(vim.json.decode, f:read("*a"))
					f:close()
					if ok and type(cfg) == "table" and type(cfg.model) == "string" and cfg.model ~= "" then
						out[#out + 1] = { agent = name, model = cfg.model, path = path }
					end
				end
			end
		end
	end
	return out
end

--- Warn about agents pinned to a model the provider no longer offers.
--- No-op when the model list is unknown (never warn on incomplete data).
--- @param session_models table?
--- @param provider string
--- @return { agent: string, model: string, path: string, suggestion: string? }[] stale entries
function M.validate_agents(session_models, provider)
	local ids = M.available_ids(session_models)
	if #ids == 0 then
		return {}
	end
	local ok_ids = {}
	for _, id in ipairs(ids) do
		ok_ids[id] = true
	end

	local stale = {}
	for _, entry in ipairs(M.pinned_models(provider)) do
		-- "auto" is a valid alias that never appears in availableModels.
		if not ok_ids[entry.model] and entry.model ~= "auto" then
			entry.suggestion = M.closest(entry.model, ids)
			stale[#stale + 1] = entry
		end
	end

	if #stale > 0 then
		local lines = { "lg: agent config pins unavailable model(s):" }
		for _, e in ipairs(stale) do
			local line = ("  %s → %q"):format(e.agent, e.model)
			if e.suggestion then
				line = line .. (" (did you mean %q?)"):format(e.suggestion)
			end
			lines[#lines + 1] = line .. "  " .. vim.fn.fnamemodify(e.path, ":~")
		end
		vim.notify(table.concat(lines, "\n"), vim.log.levels.WARN)
	end

	return stale
end

--- Turn a prompt error into a model-specific explanation, when that's the cause.
--- @param err string? error text from the prompt_error event
--- @param session_models table?
--- @param provider string
--- @return string? message  nil when the error is unrelated to model availability
function M.explain_error(err, session_models, provider)
	if not err then
		return nil
	end
	local wanted = err:match("[Mm]odel '([^']+)' is not available")
		or err:match('[Mm]odel "([^"]+)" is not available')
		or err:match("[Mm]odel '([^']+)' does not exist")
	if not wanted then
		return nil
	end

	local msg = ("Model %q is not available"):format(wanted)

	-- Name the agent that pins it, so the fix is one file away.
	for _, entry in ipairs(M.pinned_models(provider)) do
		if entry.model == wanted then
			msg = msg .. (" (pinned by agent %q in %s)"):format(entry.agent, vim.fn.fnamemodify(entry.path, ":~"))
			break
		end
	end

	local ids = M.available_ids(session_models)
	local suggestion = M.closest(wanted, ids)
	if suggestion then
		msg = msg .. ("\nClosest available: %s"):format(suggestion)
	elseif #ids > 0 then
		msg = msg .. "\nAvailable: " .. table.concat(ids, ", ")
	end
	return msg
end

return M
