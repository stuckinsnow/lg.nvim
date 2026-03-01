--- Wave spinner: cycles text color across painted region lines

local M = {}

local palette = {
  "LgWave1", "LgWave2", "LgWave3", "LgWave4",
  "LgWave5", "LgWave4", "LgWave3", "LgWave2",
}

local function ensure_highlights()
  vim.api.nvim_set_hl(0, "LgWave1", { fg = "#636380", default = true })
  vim.api.nvim_set_hl(0, "LgWave2", { fg = "#7a7a9a", default = true })
  vim.api.nvim_set_hl(0, "LgWave3", { fg = "#9898b4", default = true })
  vim.api.nvim_set_hl(0, "LgWave4", { fg = "#b4b4cc", default = true })
  vim.api.nvim_set_hl(0, "LgWave5", { fg = "#d0d0e8", default = true })
end

local WaveSpinner = {}
WaveSpinner.__index = WaveSpinner

function M.new(opts)
  ensure_highlights()
  return setmetatable({
    bufnr = opts.bufnr,
    ns_id = opts.ns_id,
    start_line = opts.start_line - 1,
    end_line = opts.end_line - 1,
    tick = 0,
    timer = vim.uv.new_timer(),
    stopped = false,
  }, WaveSpinner)
end

function WaveSpinner:start()
  self.timer:start(0, 150, vim.schedule_wrap(function()
    if self.stopped then return end
    self.tick = self.tick + 1
    pcall(vim.api.nvim_buf_clear_namespace, self.bufnr, self.ns_id, self.start_line, self.end_line + 1)
    for i = self.start_line, self.end_line do
      local hi = palette[((self.tick + i) % #palette) + 1]
      pcall(vim.api.nvim_buf_set_extmark, self.bufnr, self.ns_id, i, 0, {
        end_row = i + 1,
        hl_group = hi,
        hl_eol = true,
        priority = 200,
      })
    end
  end))
end

function WaveSpinner:stop()
  self.stopped = true
  if self.timer then self.timer:stop(); self.timer:close(); self.timer = nil end
  pcall(vim.api.nvim_buf_clear_namespace, self.bufnr, self.ns_id, self.start_line, self.end_line + 1)
end

function M.render_region(bufnr, ns_id, start_line, end_line, tick)
  ensure_highlights()
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns_id, start_line - 1, end_line)
  for i = start_line - 1, end_line - 1 do
    local hi = palette[((tick + i) % #palette) + 1]
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, i, 0, {
      end_row = i + 1, hl_group = hi, hl_eol = true, priority = 200,
    })
  end
end

return M
