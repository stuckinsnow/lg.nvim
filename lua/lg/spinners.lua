--- Spinners: animate all painted regions while requests are active

local paint = require("lg.paint")

local M = {}

local config = { spinner_type = "hint" }
local ns = vim.api.nvim_create_namespace("lg_spinner")
local timer = nil
local tick = 0
local active = 0

function M.setup(opts)
	config.spinner_type = opts.spinner_type or "hint"
end

local function get_spinner_mod()
	local t = config.spinner_type
	return t == "block" and require("lg.block-spinner")
		or t == "center" and require("lg.spinner")
		or t == "wave" and require("lg.wave-spinner")
		or require("lg.hint-spinner")
end

local function render()
	tick = tick + 1
	local regions = paint.get_all()
	local Spinner = get_spinner_mod()
	for _, r in ipairs(regions) do
		if vim.api.nvim_buf_is_valid(r.bufnr) then
			-- Use render_region if spinner supports it, otherwise basic extmarks
			if Spinner.render_region then
				Spinner.render_region(r.bufnr, ns, r.start_line, r.end_line, tick)
			end
		end
	end
end

local function clear()
	for _, r in ipairs(paint.get_all()) do
		if vim.api.nvim_buf_is_valid(r.bufnr) then
			pcall(vim.api.nvim_buf_clear_namespace, r.bufnr, ns, 0, -1)
		end
	end
end

function M.start()
	active = active + 1
	if timer then return { stop = function() M.stop() end } end
	tick = 0
	timer = vim.uv.new_timer()
	timer:start(0, 150, vim.schedule_wrap(function()
		if active <= 0 then return end
		render()
	end))
	return { stop = function() M.stop() end }
end

function M.stop()
	active = active - 1
	if active > 0 then return end
	active = 0
	if timer then timer:stop(); timer:close(); timer = nil end
	clear()
end

return M
