--- lg-cc: Paint regions + CodeCompanion tool for constrained AI editing
--- Usage:
---   require("lg-cc").setup()
---   -- Paint regions with visual selection keymaps
---   -- Use @{paint_edit} in CodeCompanion chat to edit only painted regions

local paint = require("lg-cc.paint")
local tool = require("lg-cc.tool")

local M = {}

function M.setup(opts)
  opts = opts or {}
  paint.setup(opts.paint or {})
end

--- Paint the current visual selection as an editable region
function M.paint()
  local buf = vim.api.nvim_get_current_buf()
  local start_line = vim.fn.getpos("'<")[2]
  local end_line = vim.fn.getpos("'>")[2]
  paint.add(buf, start_line, end_line)
end

--- Clear all painted regions
function M.clear()
  paint.clear()
end

--- Clear the last painted region
function M.clear_last()
  paint.clear_last()
end

--- Get the CodeCompanion tool definition
--- Use this in your codecompanion setup:
---   tools = { paint_edit = require("lg-cc").codecompanion_tool() }
function M.codecompanion_tool()
  return tool.definition()
end

return M
