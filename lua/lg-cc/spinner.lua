--- Center spinner: braille dots with "Processing" text overlay
--- Based on code from https://github.com/olimorris/codecompanion.nvim/discussions/1297

local M = {}

local default_opts = {
	spinner_text = "  Processing",
	spinner_frames = { "⣷", "⣯", "⣟", "⡿", "⢿", "⣻", "⣽", "⣾" },
	hl_group = "DiagnosticVirtualTextWarn",
	repeat_interval = 100,
	extmark = { virt_text_pos = "overlay", priority = 1001 },
}

--- @class LgCC.Spinner
--- @field bufnr number
--- @field ns_id number
--- @field line_num number
--- @field current_index number
--- @field stopped boolean
--- @field opts table
local Spinner = {}
Spinner.__index = Spinner

function M.new(opts)
	local merged = vim.tbl_deep_extend("force", default_opts, opts.opts or {})
	local width = opts.width or 0
	local center = width - merged.spinner_text:len()
	local col = center > 0 and math.floor(center / 2) or 0

	local timer = vim.uv.new_timer()
	if not timer then
		return nil
	end

	return setmetatable({
		bufnr = opts.bufnr,
		ns_id = opts.ns_id,
		line_num = opts.line_num - 1,
		current_index = 1,
		timer = timer,
		stopped = false,
		opts = vim.tbl_deep_extend("force", merged, { extmark = { virt_text_win_col = col } }),
	}, Spinner)
end

function Spinner:virt_text()
	return {
		{ self.opts.spinner_text .. " " .. self.opts.spinner_frames[self.current_index] .. " ", self.opts.hl_group },
	}
end

function Spinner:set_extmark()
	return vim.api.nvim_buf_set_extmark(self.bufnr, self.ns_id, self.line_num, 0, self.opts.extmark)
end

function Spinner:start()
	self.opts.extmark.virt_text = self:virt_text()
	self.opts.extmark.id = self:set_extmark()
	if not self.timer then
		return
	end
	---@diagnostic disable-next-line: undefined-field
	self.timer:start(
		0,
		self.opts.repeat_interval,
		vim.schedule_wrap(function()
			if self.stopped then
				return
			end
			self.current_index = self.current_index % #self.opts.spinner_frames + 1
			self.opts.extmark.virt_text = self:virt_text()
			self:set_extmark()
		end)
	)
end

function Spinner:stop()
	self.stopped = true
	if self.timer then
		---@diagnostic disable-next-line: undefined-field
		self.timer:stop()
		---@diagnostic disable-next-line: undefined-field
		self.timer:close()
		self.timer = nil
	end
	if self.opts.extmark and self.opts.extmark.id then
		pcall(vim.api.nvim_buf_del_extmark, self.bufnr, self.ns_id, self.opts.extmark.id)
	end
end

return M
