--- Hint spinner: single "AI is processing" eol virtual text on the first line of each painted region

local M = {}

local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local hl = "DiagnosticVirtualTextHint"

local function virt_text(tick)
	local frame = frames[(tick % #frames) + 1]
	return { { "  " .. frame .. " AI is processing", hl } }
end

local HintSpinner = {}
HintSpinner.__index = HintSpinner

function M.new(opts)
	return setmetatable({
		bufnr = opts.bufnr,
		ns_id = opts.ns_id,
		start_line = opts.start_line - 1,
		end_line = opts.end_line - 1,
		tick = 0,
		timer = vim.uv.new_timer(),
		stopped = false,
	}, HintSpinner)
end

function HintSpinner:start()
	self.timer:start(0, 150, vim.schedule_wrap(function()
		if self.stopped then return end
		self.tick = self.tick + 1
		pcall(vim.api.nvim_buf_set_extmark, self.bufnr, self.ns_id, self.start_line, 0, {
			virt_text = virt_text(self.tick),
			virt_text_pos = "eol",
			priority = 1000,
			id = self.start_line + 1,
		})
	end))
end

function HintSpinner:stop()
	self.stopped = true
	if self.timer then self.timer:stop(); self.timer:close(); self.timer = nil end
	pcall(vim.api.nvim_buf_clear_namespace, self.bufnr, self.ns_id, self.start_line, self.end_line + 1)
end

function M.render_region(bufnr, ns_id, start_line, end_line, tick)
	pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns_id, start_line - 1, end_line)
	pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, start_line - 1, 0, {
		virt_text = virt_text(tick),
		virt_text_pos = "eol",
		priority = 1000,
	})
end

return M
