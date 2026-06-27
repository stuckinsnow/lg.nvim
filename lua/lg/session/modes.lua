--- Maps lg mode_ids to each backend's agent/mode name.
--- kiro uses the mode_id as-is; opencode maps to a configured agent.

local M = {}

local opencode_modes = {
	lg = "lg",
	["lg-chat"] = "lg-chat",
	["lg-plan"] = "lg-plan",
	["lg-oneshot"] = "lg-oneshot",
	["lg-info"] = "lg-info",
	reviewer = "reviewer",
	suggester = "suggester",
	helper = "helper",
	asker = "asker",
	["lg-shell"] = "lg-shell",
	devlens = "devlens",
	fullstack = "fullstack",
	kiro_default = "lg-chat",
	kiro_planner = "lg-plan",
}

--- Resolve an lg mode_id to the backend's agent/mode name for `provider`.
function M.resolve_mode(provider, mode_id)
	if provider == "opencode" then
		return opencode_modes[mode_id] or "build"
	end
	return mode_id
end

return M
