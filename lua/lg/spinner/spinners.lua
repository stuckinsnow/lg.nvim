--- Spinners: animate painted regions while requests are active

local M = {}

local config = { spinner_type = "hint" }
local ns = vim.api.nvim_create_namespace("lg.spinner.spinner")
local timer = nil
local tick = 0
local handles = {} -- active handles, each with a region snapshot

function M.setup(opts)
	config.spinner_type = opts.spinner_type or "hint"
end

local function get_spinner_mod()
	local t = config.spinner_type
	return t == "block" and require("lg.spinner.block-spinner")
		or t == "center" and require("lg.spinner.spinner")
		or t == "wave" and require("lg.spinner.wave-spinner")
		or require("lg.spinner.hint-spinner")
end

local function render()
	tick = tick + 1
	local Spinner = get_spinner_mod()
	if not Spinner.render_region then return end
	for _, h in ipairs(handles) do
		for _, r in ipairs(h.regions) do
			if vim.api.nvim_buf_is_valid(r.bufnr) then
				Spinner.render_region(r.bufnr, ns, r.start_line, r.end_line, tick)
			end
		end
	end
end

local function clear_regions(regions)
	for _, r in ipairs(regions) do
		if vim.api.nvim_buf_is_valid(r.bufnr) then
			pcall(vim.api.nvim_buf_clear_namespace, r.bufnr, ns, r.start_line - 1, r.end_line)
		end
	end
end

local function start_timer()
	if timer then return end
	tick = 0
	timer = vim.uv.new_timer()
	timer:start(0, 150, vim.schedule_wrap(function()
		if #handles == 0 then return end
		render()
	end))
end

local function stop_timer()
	if #handles > 0 then return end
	if timer then timer:stop(); timer:close(); timer = nil end
end

function M.start(regions)
	local snapshot = regions or {}
	local handle = { regions = snapshot }
	table.insert(handles, handle)
	start_timer()
	return {
		stop = function()
			for i, h in ipairs(handles) do
				if h == handle then table.remove(handles, i); break end
			end
			clear_regions(snapshot)
			stop_timer()
		end,
	}
end

function M.stop() end

return M
