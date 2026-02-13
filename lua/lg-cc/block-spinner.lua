--- Block spinner: animated diagonal lines overlay on painted regions
--- Based on code from https://github.com/olimorris/codecompanion.nvim/discussions/1297

local M = {}

local default_opts = {
  hl_group = "Comment",
  repeat_interval = 100,
  extmark = { virt_text_pos = "overlay", priority = 1000 },
  patterns = { "╲  ", " ╲ ", "  ╲" },
}

--- @class LgCC.BlockSpinner
--- @field bufnr number
--- @field ns_id number
--- @field start_line number 0-indexed
--- @field end_line number 0-indexed
--- @field ids table<number, number>
--- @field patterns string[]
--- @field current_index number
--- @field timer uv_timer_t?
--- @field stopped boolean
--- @field opts table
--- @field width number
--- @field border_top string
--- @field border_bottom string
local BlockSpinner = {}
BlockSpinner.__index = BlockSpinner

function M.new(opts)
  local merged = vim.tbl_deep_extend("force", default_opts, opts.opts or {})
  local lines = vim.api.nvim_buf_get_lines(opts.bufnr, opts.start_line - 1, opts.end_line, false)
  local width = vim.fn.max(vim.iter(lines):map(function(l) return vim.fn.strdisplaywidth(l) end):totable())

  local pat_width = vim.fn.strdisplaywidth(merged.patterns[1])
  local reps = pat_width > 0 and math.ceil(width / pat_width) or width
  width = reps * pat_width

  local patterns = {}
  for _, p in ipairs(merged.patterns) do
    table.insert(patterns, string.rep(p, reps))
  end

  return setmetatable({
    bufnr = opts.bufnr,
    ns_id = opts.ns_id,
    start_line = opts.start_line - 1,
    end_line = opts.end_line - 1,
    ids = {},
    patterns = patterns,
    current_index = 1,
    timer = vim.uv.new_timer(),
    stopped = false,
    opts = merged,
    width = width,
    border_top = "╭" .. string.rep("─", width) .. "╮",
    border_bottom = "╰" .. string.rep("─", width) .. "╯",
  }, BlockSpinner)
end

function BlockSpinner:virt_text(i)
  if #self.patterns == 0 then return {} end
  local height = self.end_line - self.start_line + 1
  if height <= 2 then
    local idx = ((i + self.current_index - 1) % #self.patterns) + 1
    return { { self.patterns[idx], self.opts.hl_group } }
  end
  if i == self.start_line then return { { self.border_top, self.opts.hl_group } } end
  if i == self.end_line then return { { self.border_bottom, self.opts.hl_group } } end
  local idx = ((i + self.current_index - 1) % #self.patterns) + 1
  return { { "│" .. self.patterns[idx] .. "│", self.opts.hl_group } }
end

function BlockSpinner:start()
  for i = self.start_line, self.end_line do
    self.ids[i] = vim.api.nvim_buf_set_extmark(self.bufnr, self.ns_id, i, 0,
      vim.tbl_deep_extend("force", self.opts.extmark, { virt_text = self:virt_text(i) }))
  end
  self.timer:start(0, self.opts.repeat_interval, vim.schedule_wrap(function()
    if self.stopped then return end
    self.current_index = (self.current_index % #self.patterns) + 1
    for i, id in pairs(self.ids) do
      local pos = vim.api.nvim_buf_get_extmark_by_id(self.bufnr, self.ns_id, id, {})
      pcall(vim.api.nvim_buf_set_extmark, self.bufnr, self.ns_id, pos[1], 0,
        vim.tbl_deep_extend("force", self.opts.extmark, { virt_text = self:virt_text(i), id = id }))
    end
  end))
end

function BlockSpinner:stop()
  self.stopped = true
  if self.timer then self.timer:stop(); self.timer:close(); self.timer = nil end
  for _, id in pairs(self.ids) do
    pcall(vim.api.nvim_buf_del_extmark, self.bufnr, self.ns_id, id)
  end
  self.ids = {}
end

return M
