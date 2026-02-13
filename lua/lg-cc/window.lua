--- Window: optional side panel showing painted regions and session history

local paint = require("lg-cc.paint")
local session = require("lg-cc.session")

local M = {}

--- @class LgCC.WindowState
--- @field bufnr number?
--- @field winnr number?
--- @field history { type: string, text: string }[]

--- @type LgCC.WindowState
local state = {
  bufnr = nil,
  winnr = nil,
  history = {},
}

local opts = {}

function M.setup(user_opts)
  opts = vim.tbl_deep_extend("force", {
    width = 50,
    position = "right", -- "right" or "left"
  }, user_opts or {})
end

--- @param prompt string
function M.add_prompt(prompt)
  table.insert(state.history, { type = "prompt", text = prompt })
  M.refresh()
end

--- @param text string
function M.add_result(text)
  table.insert(state.history, { type = "result", text = text })
  M.refresh()
end

--- Append streaming text from agent
--- @param chunk string
function M.append_agent_text(chunk)
  -- Find or create the current agent message entry
  local last = state.history[#state.history]
  if not last or last.type ~= "agent" then
    table.insert(state.history, { type = "agent", text = chunk })
  else
    last.text = last.text .. chunk
  end
  M.refresh()
end

--- Build buffer content from current state
--- @return string[]
local function render()
  local lines = { "═══ lg-cc ═══", "" }

  -- Session status
  local status = session.is_active() and "● active" or "○ idle"
  table.insert(lines, "Session: " .. status)
  table.insert(lines, "")

  -- Painted regions
  local regions = paint.get_all()
  table.insert(lines, "── Editable Regions (" .. #regions .. ") ──")
  if #regions == 0 then
    table.insert(lines, "  (none)")
  else
    for i, r in ipairs(regions) do
      local fname = r.file ~= "" and vim.fn.fnamemodify(r.file, ":~:.") or "[unnamed]"
      table.insert(lines, string.format("  [%d] %s:%d-%d", i - 1, fname, r.start_line, r.end_line))
    end
  end
  table.insert(lines, "")

  -- Context regions
  local ctx_regions = require("lg-cc.context").get_all()
  table.insert(lines, "── Context (" .. #ctx_regions .. ") ──")
  if #ctx_regions == 0 then
    table.insert(lines, "  (none)")
  else
    for i, r in ipairs(ctx_regions) do
      local fname = r.file ~= "" and vim.fn.fnamemodify(r.file, ":~:.") or "[unnamed]"
      table.insert(lines, string.format("  [%d] %s:%d-%d", i - 1, fname, r.start_line, r.end_line))
    end
  end
  table.insert(lines, "")

  -- History
  table.insert(lines, "── History ──")
  if #state.history == 0 then
    table.insert(lines, "  (empty)")
  else
    for _, entry in ipairs(state.history) do
      if entry.type == "prompt" then
        table.insert(lines, "  > " .. entry.text)
      elseif entry.type == "result" then
        table.insert(lines, "  ✓ " .. entry.text)
      elseif entry.type == "agent" then
        for _, l in ipairs(vim.split(entry.text, "\n")) do
          table.insert(lines, "  " .. l)
        end
      end
    end
  end

  return lines
end

--- Ensure buffer exists
local function ensure_buf()
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    return state.bufnr
  end
  state.bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[state.bufnr].buftype = "nofile"
  vim.bo[state.bufnr].filetype = "lgcc"
  vim.bo[state.bufnr].modifiable = false
  vim.api.nvim_buf_set_name(state.bufnr, "lg-cc://panel")
  return state.bufnr
end

--- Update buffer content if window is open
function M.refresh()
  if not state.winnr or not vim.api.nvim_win_is_valid(state.winnr) then
    state.winnr = nil
    return
  end
  local buf = ensure_buf()
  local lines = render()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

function M.open()
  if state.winnr and vim.api.nvim_win_is_valid(state.winnr) then
    return -- already open
  end

  local buf = ensure_buf()
  local cmd = opts.position == "left" and "topleft" or "botright"
  vim.cmd(cmd .. " " .. opts.width .. "vsplit")
  state.winnr = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.winnr, buf)

  vim.wo[state.winnr].number = false
  vim.wo[state.winnr].relativenumber = false
  vim.wo[state.winnr].signcolumn = "no"
  vim.wo[state.winnr].winfixwidth = true
  vim.wo[state.winnr].wrap = true

  M.refresh()

  -- Return focus to previous window
  vim.cmd("wincmd p")
end

function M.close()
  if state.winnr and vim.api.nvim_win_is_valid(state.winnr) then
    vim.api.nvim_win_close(state.winnr, true)
  end
  state.winnr = nil
end

function M.toggle()
  if state.winnr and vim.api.nvim_win_is_valid(state.winnr) then
    M.close()
  else
    M.open()
  end
end

--- Clear history (called when session is cleared)
function M.clear_history()
  state.history = {}
  M.refresh()
end

return M
