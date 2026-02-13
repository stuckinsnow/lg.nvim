--- lg-cc: Paint regions + CodeCompanion tool for constrained AI editing

local paint = require("lg-cc.paint")
local diff = require("lg-cc.diff")
local tool = require("lg-cc.tool")
local server = require("lg-cc.server")

local M = {}

function M.setup(opts)
  opts = opts or {}
  paint.setup(opts.paint or {})
  server.start()

  -- Write MCP config so kiro-cli discovers the server
  local mcp_bin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h") .. "/mcp/lg-cc-mcp"
  local mcp_config_dir = (os.getenv("HOME") or "") .. "/.kiro/settings"
  local mcp_config_path = mcp_config_dir .. "/mcp.json"

  local existing = {}
  local f = io.open(mcp_config_path, "r")
  if f then
    local ok, parsed = pcall(vim.json.decode, f:read("*a"))
    f:close()
    if ok and parsed then existing = parsed end
  end

  existing.mcpServers = existing.mcpServers or {}
  existing.mcpServers["lg-cc"] = {
    command = mcp_bin,
    args = {},
    env = { LGCC_SOCK = server.get_sock_path() },
  }

  vim.fn.mkdir(mcp_config_dir, "p")
  f = io.open(mcp_config_path, "w")
  if f then
    f:write(vim.json.encode(existing))
    f:close()
  end

  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function() server.stop() end,
  })
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

--- Clear AI edit markers from current buffer
function M.clear_marks()
  diff.clear()
end

function M.codecompanion_tool()
  return tool.definition()
end

function M.sock_path()
  return server.get_sock_path()
end

return M
