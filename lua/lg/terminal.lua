--- Optional snacks.nvim terminal split override while the lg sidebar is open

local M = {}

local split_override = nil
local prev_split = nil

---@param split? "horizontal"|"vertical"|false
function M.setup(split)
	split_override = split or nil
end

function M.on_open()
	if not split_override then
		return
	end
	local ok, Snacks = pcall(require, "snacks")
	if not (ok and Snacks.config and Snacks.config.terminal) then
		return
	end
	if prev_split == nil then
		prev_split = Snacks.config.terminal.split or false
	end
	Snacks.config.terminal.split = split_override
end

function M.on_close()
	if prev_split == nil then
		return
	end
	local ok, Snacks = pcall(require, "snacks")
	if ok and Snacks.config and Snacks.config.terminal then
		Snacks.config.terminal.split = prev_split or nil
	end
	prev_split = nil
end

return M
