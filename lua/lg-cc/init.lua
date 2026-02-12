--- lg-cc: Paint regions + CodeCompanion tool for constrained AI editing

local paint = require("lg-cc.paint")
local diff = require("lg-cc.diff")
local tool = require("lg-cc.tool")

local M = {}

function M.setup(opts)
  opts = opts or {}
  paint.setup(opts.paint or {})
end

function M.paint()
  local buf = vim.api.nvim_get_current_buf()
  local start_line = vim.fn.getpos("'<")[2]
  local end_line = vim.fn.getpos("'>")[2]
  paint.add(buf, start_line, end_line)
end

function M.clear()
  paint.clear()
end

function M.clear_last()
  paint.clear_last()
end

function M.accept()
  diff.accept()
end

function M.reject()
  diff.reject()
end

function M.codecompanion_tool()
  return tool.definition()
end

return M
