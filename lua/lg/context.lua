--- Context paint: read-only regions included as reference in prompts
--- Same structure as paint.lua but different highlights and namespace

local M = {}

local ns = vim.api.nvim_create_namespace("lg_context")

--- @type Lg.Region[]
local regions = {}

local function ensure_highlights()
  vim.api.nvim_set_hl(0, "LgContextLine", { bg = "#1a2a3a", default = true })
  vim.api.nvim_set_hl(0, "LgContextSign", { fg = "#61afef", default = true })
end

--- @param bufnr number
--- @param start_line number 1-indexed
--- @param end_line number 1-indexed
--- @param label? string optional label (e.g. search term)
function M.add(bufnr, start_line, end_line, label)
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
      end_line = row + 1, hl_group = "LgContextLine", hl_eol = true, priority = 105,
    })
    vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
      sign_text = sign, sign_hl_group = "LgContextSign", priority = 105,
    })
  end
  for _, r in ipairs(regions) do
    if r.bufnr == bufnr and r.start_line == start_line and r.end_line == end_line then
      return
    end
  end
  table.insert(regions, { bufnr = bufnr, start_line = start_line, end_line = end_line, label = label })
end

--- @return { bufnr: number, start_line: number, end_line: number, lines: string[], file: string }[]
function M.get_all()
  local result = {}
  for _, r in ipairs(regions) do
    if vim.api.nvim_buf_is_valid(r.bufnr) then
      table.insert(result, {
        bufnr = r.bufnr,
        start_line = r.start_line,
        end_line = r.end_line,
        lines = vim.api.nvim_buf_get_lines(r.bufnr, r.start_line - 1, r.end_line, false),
        file = vim.api.nvim_buf_get_name(r.bufnr),
        label = r.label,
      })
    end
  end
  return result
end

function M.count() return #regions end

--- @type { query: string, results: table[] }[]
local searches = {}

function M.get_searches() return searches end
function M.clear_searches() searches = {} end

function M.add_search(query, results)
  table.insert(searches, { query = query, results = results })
end

--- @type string[]
local files = {}

function M.add_file(path)
  path = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(path) == 0 then
    vim.notify("lg: file not found: " .. path, vim.log.levels.WARN)
    return
  end
  table.insert(files, path)
end

function M.get_files() return files end

function M.clear()
  for _, r in ipairs(regions) do
    if vim.api.nvim_buf_is_valid(r.bufnr) then
      vim.api.nvim_buf_clear_namespace(r.bufnr, ns, 0, -1)
    end
  end
  regions = {}
  files = {}
  searches = {}
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

return M
