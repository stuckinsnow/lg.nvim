--- Paint module: manages painted regions with extmarks
--- Regions are visual selections that constrain where AI can edit

--- @class LgCC.Region
--- @field bufnr number
--- @field start_line number 1-indexed
--- @field end_line number 1-indexed
--- @field ns_id number namespace for this region's extmarks

local M = {}

local ns = vim.api.nvim_create_namespace("lg_cc_paint")

--- @type LgCC.Region[]
local regions = {}

local function ensure_highlights()
  local ok, vis = pcall(vim.api.nvim_get_hl, 0, { name = "Visual" })
  local bg = (ok and vis and vis.bg) or 0x3a3a5c
  local r = math.min(255, math.floor(bg / 0x10000) + 30)
  local g = math.min(255, math.floor((bg / 0x100) % 0x100) + 30)
  local b = math.min(255, math.floor(bg % 0x100) + 30)
  vim.api.nvim_set_hl(0, "LgCCPaintLine", { bg = r * 0x10000 + g * 0x100 + b, default = true })
  vim.api.nvim_set_hl(0, "LgCCPaintSign", { fg = "#e5c07b", default = true })
end

--- @param bufnr number
--- @param start_line number 1-indexed
--- @param end_line number 1-indexed
function M.add(bufnr, start_line, end_line)
  ensure_highlights()

  for row = start_line - 1, end_line - 1 do
    local total = end_line - start_line + 1
    local sign
    if total == 1 then
      sign = "│"
    elseif row == start_line - 1 then
      sign = "┌"
    elseif row == end_line - 1 then
      sign = "└"
    else
      sign = "│"
    end

    vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
      end_line = row + 1,
      hl_group = "LgCCPaintLine",
      hl_eol = true,
      priority = 110,
    })
    vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
      sign_text = sign,
      sign_hl_group = "LgCCPaintSign",
      priority = 110,
    })
  end

  table.insert(regions, {
    bufnr = bufnr,
    start_line = start_line,
    end_line = end_line,
  })
end

--- Get all regions with their current line content
--- @return { bufnr: number, start_line: number, end_line: number, lines: string[], file: string }[]
function M.get_all()
  local result = {}
  for _, r in ipairs(regions) do
    if vim.api.nvim_buf_is_valid(r.bufnr) then
      local lines = vim.api.nvim_buf_get_lines(r.bufnr, r.start_line - 1, r.end_line, false)
      table.insert(result, {
        bufnr = r.bufnr,
        start_line = r.start_line,
        end_line = r.end_line,
        lines = lines,
        file = vim.api.nvim_buf_get_name(r.bufnr),
      })
    end
  end
  return result
end

--- @return number
function M.count()
  return #regions
end

--- Shift regions in the same buffer after an edit changes line count
--- @param bufnr number
--- @param edit_start number 1-indexed start line of the edit
--- @param delta number lines added (positive) or removed (negative)
function M.shift_after(bufnr, edit_start, delta)
  if delta == 0 then return end
  for _, r in ipairs(regions) do
    if r.bufnr == bufnr and r.start_line > edit_start then
      r.start_line = r.start_line + delta
      r.end_line = r.end_line + delta
    end
  end
end

function M.clear()
  for _, r in ipairs(regions) do
    if vim.api.nvim_buf_is_valid(r.bufnr) then
      vim.api.nvim_buf_clear_namespace(r.bufnr, ns, 0, -1)
    end
  end
  regions = {}
end

function M.clear_last()
  if #regions == 0 then return end
  local r = table.remove(regions)
  if vim.api.nvim_buf_is_valid(r.bufnr) then
    local marks = vim.api.nvim_buf_get_extmarks(r.bufnr, ns, { r.start_line - 1, 0 }, { r.end_line - 1, -1 }, {})
    for _, mark in ipairs(marks) do
      vim.api.nvim_buf_del_extmark(r.bufnr, ns, mark[1])
    end
  end
end

function M.setup(_) end

return M
