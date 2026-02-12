--- Inline diff with accept/reject for paint edits
--- Shows old code as red virtual lines above, new code highlighted green

--- @class LgCC.Diff.PendingChange
--- @field id number
--- @field bufnr number
--- @field original_lines string[]
--- @field start_row number 0-indexed
--- @field end_row number 0-indexed (exclusive, updated after replacement)
--- @field extmark_ids number[]

local M = {}

local ns = vim.api.nvim_create_namespace("lg_cc_diff")

--- @type table<number, LgCC.Diff.PendingChange>
local pending = {}
local id_counter = 0

--- @param change LgCC.Diff.PendingChange
--- @param new_lines string[]
local function show_overlay(change, new_lines)
  local bufnr = change.bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  -- Snapshot original, then replace
  vim.api.nvim_buf_set_lines(bufnr, change.start_row, change.end_row, false, new_lines)
  change.end_row = change.start_row + #new_lines

  change.extmark_ids = {}

  -- Old lines as red virtual text above
  local virt_lines = {}
  for _, line in ipairs(change.original_lines) do
    table.insert(virt_lines, { { "- " .. line, "DiffDelete" } })
  end
  if #virt_lines > 0 then
    local id = vim.api.nvim_buf_set_extmark(bufnr, ns, change.start_row, 0, {
      virt_lines = virt_lines,
      virt_lines_above = true,
    })
    table.insert(change.extmark_ids, id)
  end

  -- New lines highlighted green
  for i = change.start_row, change.end_row - 1 do
    local id = vim.api.nvim_buf_set_extmark(bufnr, ns, i, 0, {
      line_hl_group = "DiffAdd",
    })
    table.insert(change.extmark_ids, id)
  end
end

--- @param bufnr number
--- @param row number 0-indexed
--- @return LgCC.Diff.PendingChange|nil
local function find_at_cursor(bufnr, row)
  for _, c in pairs(pending) do
    if c.bufnr == bufnr and row >= c.start_row and row < c.end_row then
      return c
    end
  end
  return nil
end

--- @param change LgCC.Diff.PendingChange
local function clear_extmarks(change)
  if vim.api.nvim_buf_is_valid(change.bufnr) then
    for _, eid in ipairs(change.extmark_ids) do
      pcall(vim.api.nvim_buf_del_extmark, change.bufnr, ns, eid)
    end
  end
end

--- Store and display a pending change
--- @param bufnr number
--- @param start_row number 0-indexed
--- @param end_row number 0-indexed (exclusive)
--- @param new_lines string[]
function M.store(bufnr, start_row, end_row, new_lines)
  local original = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row, false)
  id_counter = id_counter + 1
  local change = {
    id = id_counter,
    bufnr = bufnr,
    original_lines = original,
    start_row = start_row,
    end_row = end_row,
    extmark_ids = {},
  }
  pending[change.id] = change
  -- Schedule overlay so extmarks are set after CodeCompanion's tool handling completes
  vim.schedule(function()
    if pending[change.id] then
      show_overlay(change, new_lines)
    end
  end)
end

--- Accept change at cursor — new code is already in the buffer, just clear overlay
function M.accept()
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local change = find_at_cursor(bufnr, row)
  if not change then
    vim.notify("No pending paint edit at cursor", vim.log.levels.WARN)
    return
  end
  clear_extmarks(change)
  pending[change.id] = nil
  -- Re-indent the accepted region via conform/LSP
  pcall(function()
    vim.api.nvim_win_set_cursor(0, { change.start_row + 1, 0 })
    local end_line = change.end_row
    vim.cmd(string.format("silent! %d,%dnormal! ==", change.start_row + 1, end_line))
  end)
  vim.notify("Paint edit accepted", vim.log.levels.INFO)
end

--- Reject change at cursor — restore original lines
function M.reject()
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local change = find_at_cursor(bufnr, row)
  if not change then
    vim.notify("No pending paint edit at cursor", vim.log.levels.WARN)
    return
  end
  clear_extmarks(change)
  vim.api.nvim_buf_set_lines(change.bufnr, change.start_row, change.end_row, false, change.original_lines)
  pending[change.id] = nil
  vim.notify("Paint edit rejected", vim.log.levels.INFO)
end

--- @return boolean
function M.has_pending()
  return next(pending) ~= nil
end

return M
