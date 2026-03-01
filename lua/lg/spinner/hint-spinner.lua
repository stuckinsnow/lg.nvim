--- Hint spinner: animated wave pattern as eol virtual text on painted regions
--- Rippling wave with color cycling down the region

local M = {}

local waves = { "ꞏ", "∘", "○", "◎", "●", "◎", "○", "∘" }
local hls = {
  "DiagnosticVirtualTextHint",
  "DiagnosticVirtualTextOk",
  "DiagnosticVirtualTextInfo",
  "DiagnosticVirtualTextWarn",
}

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
  self.timer:start(0, 200, vim.schedule_wrap(function()
    if self.stopped then return end
    self.tick = self.tick + 1
    for i = self.start_line, self.end_line do
      local offset = i - self.start_line
      local parts = {}
      for j = 0, 4 do
        local wi = ((self.tick + offset * 2 + j) % #waves) + 1
        local hi = ((self.tick + offset + j) % #hls) + 1
        parts[#parts + 1] = { waves[wi] .. " ", hls[hi] }
      end
      pcall(vim.api.nvim_buf_set_extmark, self.bufnr, self.ns_id, i, 0, {
        virt_text = parts,
        virt_text_pos = "eol",
        priority = 1000,
        id = self.start_line * 10000 + i,
      })
    end
  end))
end

function HintSpinner:stop()
  self.stopped = true
  if self.timer then self.timer:stop(); self.timer:close(); self.timer = nil end
  pcall(vim.api.nvim_buf_clear_namespace, self.bufnr, self.ns_id, self.start_line, self.end_line + 1)
end

function M.render_region(bufnr, ns_id, start_line, end_line, tick)
  for i = start_line - 1, end_line - 1 do
    local offset = i - (start_line - 1)
    local parts = {}
    for j = 0, 4 do
      local wi = ((tick + offset * 2 + j) % #waves) + 1
      local hi = ((tick + offset + j) % #hls) + 1
      parts[#parts + 1] = { waves[wi] .. " ", hls[hi] }
    end
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, i, 0, {
      virt_text = parts, virt_text_pos = "eol", priority = 1000,
    })
  end
end

return M
