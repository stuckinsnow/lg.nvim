--- lg-cc: Paint regions + direct kiro-cli ACP for constrained AI editing

local paint = require("lg-cc.paint")
local context = require("lg-cc.context")
local diff = require("lg-cc.diff")
local session = require("lg-cc.session")
local server = require("lg-cc.server")
local window = require("lg-cc.window")

local M = {}

local ns_spinner = vim.api.nvim_create_namespace("lg_cc_spinner")

--- @type table[] active spinner pairs
local active_spinners = {}

function M.setup(opts)
  opts = opts or {}
  paint.setup(opts.paint or {})
  session.setup(opts.session or {})
  window.setup(opts.window or {})

  server.start()

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
  if f then f:write(vim.json.encode(existing)); f:close() end

  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function() server.stop() end,
  })
end

--- Paint current visual selection (editable)
function M.paint()
  local buf = vim.api.nvim_get_current_buf()
  local start_line = vim.fn.getpos("'<")[2]
  local end_line = vim.fn.getpos("'>")[2]
  paint.add(buf, start_line, end_line)
  window.refresh()
end

--- Paint current visual selection as read-only context
function M.context_paint()
  local buf = vim.api.nvim_get_current_buf()
  local start_line = vim.fn.getpos("'<")[2]
  local end_line = vim.fn.getpos("'>")[2]
  context.add(buf, start_line, end_line)
  window.refresh()
end

--- Stop all active spinners
local function stop_spinners()
  for _, s in ipairs(active_spinners) do s:stop() end
  active_spinners = {}
end

--- Start hint spinners on all painted regions
local function start_spinners(regions)
  stop_spinners()
  local HintSpinner = require("lg-cc.hint-spinner")
  for _, r in ipairs(regions) do
    local ns = vim.api.nvim_create_namespace("lg_cc_spinner_" .. r.bufnr .. "_" .. r.start_line)
    local hint = HintSpinner.new({ bufnr = r.bufnr, ns_id = ns, start_line = r.start_line, end_line = r.end_line })
    hint:start()
    table.insert(active_spinners, hint)
  end
end

--- Send painted regions + prompt to kiro-cli
--- @param opts? { prompt?: string }
function M.send(opts)
  opts = opts or {}
  local regions = paint.get_all()
  if #regions == 0 then
    vim.notify("lg-cc: no painted regions", vim.log.levels.WARN)
    return
  end

  local function do_send(prompt)
    if not prompt or prompt == "" then return end
    window.add_prompt(prompt)
    start_spinners(regions)
    session.send(prompt, regions, context.get_all(), function()
      vim.schedule(stop_spinners)
    end)
  end

  if opts.prompt then
    do_send(opts.prompt)
  else
    require("lg-cc.prompt").open(do_send)
  end
end

function M.clear() paint.clear(); window.refresh() end
function M.clear_last() paint.clear_last(); window.refresh() end
function M.clear_context() context.clear(); window.refresh() end
function M.clear_context_last() context.clear_last(); window.refresh() end
function M.clear_all() paint.clear(); context.clear(); window.refresh() end
function M.clear_marks() diff.clear() end

function M.clear_session()
  session.clear()
  window.clear_history()
end

function M.toggle_window() window.toggle() end
function M.select_model() session.select_model() end
function M.select_provider() session.select_provider() end

return M
