--- Window: side column with stacked section windows + markdown chat

local paint = require("lg-cc.paint")
local session = require("lg-cc.session")

local M = {}

local state = {
  -- bufs: status, regions, context, chat
  bufs = {},
  -- wins: status, regions, context, chat
  wins = {},
  history = {},
}

local opts = {}

-- Helpers

local function win_valid(w) return w and vim.api.nvim_win_is_valid(w) end
local function buf_valid(b) return b and vim.api.nvim_buf_is_valid(b) end

local function make_buf(name, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = ft
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, name)
  return buf
end

local function ensure_buf(key, ft)
  if buf_valid(state.bufs[key]) then return state.bufs[key] end
  state.bufs[key] = make_buf("lg-cc://" .. key, ft)
  return state.bufs[key]
end

local function set_win_opts(w)
  vim.wo[w].number = false
  vim.wo[w].relativenumber = false
  vim.wo[w].signcolumn = "no"
  vim.wo[w].winfixwidth = true
  vim.wo[w].winfixheight = true
  vim.wo[w].wrap = true
  vim.wo[w].cursorline = false
  vim.wo[w].spell = false
  vim.wo[w].foldcolumn = "1"
end

local function ensure_highlights()
  vim.api.nvim_set_hl(0, "LgCCTitle", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "LgCCSeparator", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "LgCCRegionId", { link = "Number", default = true })
  vim.api.nvim_set_hl(0, "LgCCFile", { link = "Directory", default = true })
  vim.api.nvim_set_hl(0, "LgCCStatus", { link = "DiagnosticOk", default = true })
end

--- Write lines + highlights into a buffer
local function set_buf_content(buf, lines, hls)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  if hls then
    local ns = vim.api.nvim_create_namespace("lg_cc_" .. buf)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, hl in ipairs(hls) do
      local line, cs, ce, hg = hl[1], hl[2], hl[3], hl[4]
      if ce == -1 then ce = #lines[line + 1] end
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, line, cs, { end_col = ce, hl_group = hg, priority = 100 })
    end
  end
  vim.bo[buf].modifiable = false
end

-- Renderers

local function render_status()
  local status = session.is_active() and "● active" or "○ idle"
  return { "Session: " .. status }, { { 0, 0, -1, "LgCCStatus" } }
end

local function render_regions()
  ensure_highlights()
  local lines = {}
  local hls = {}
  local regions = paint.get_all()
  table.insert(lines, "Editable Regions (" .. #regions .. ")")
  table.insert(hls, { 0, 0, -1, "LgCCTitle" })
  if #regions == 0 then
    table.insert(lines, "  (none)")
    table.insert(hls, { 1, 0, -1, "LgCCSeparator" })
  else
    for i, r in ipairs(regions) do
      local fname = r.file ~= "" and vim.fn.fnamemodify(r.file, ":~:.") or "[unnamed]"
      local txt = string.format("  [%d] %s:%d-%d", i - 1, fname, r.start_line, r.end_line)
      table.insert(lines, txt)
      local idx = #lines - 1
      table.insert(hls, { idx, 2, 2 + #tostring(i - 1) + 2, "LgCCRegionId" })
      table.insert(hls, { idx, 2 + #tostring(i - 1) + 3, -1, "LgCCFile" })
    end
  end
  return lines, hls
end

local function render_context()
  ensure_highlights()
  local lines = {}
  local hls = {}
  local ctx = require("lg-cc.context").get_all()
  table.insert(lines, "Context (" .. #ctx .. ")")
  table.insert(hls, { 0, 0, -1, "LgCCTitle" })
  if #ctx == 0 then
    table.insert(lines, "  (none)")
    table.insert(hls, { 1, 0, -1, "LgCCSeparator" })
  else
    for i, r in ipairs(ctx) do
      local fname = r.file ~= "" and vim.fn.fnamemodify(r.file, ":~:.") or "[unnamed]"
      local txt = string.format("  [%d] %s:%d-%d", i - 1, fname, r.start_line, r.end_line)
      table.insert(lines, txt)
      local idx = #lines - 1
      table.insert(hls, { idx, 2, 2 + #tostring(i - 1) + 2, "LgCCRegionId" })
      table.insert(hls, { idx, 2 + #tostring(i - 1) + 3, -1, "LgCCFile" })
    end
  end
  return lines, hls
end

local function render_chat()
  local lines = {}
  if #state.history == 0 then
    table.insert(lines, "*No conversation yet.*")
    return lines
  end
  for i, entry in ipairs(state.history) do
    if i > 1 then
      table.insert(lines, "")
      table.insert(lines, "---")
      table.insert(lines, "")
    end
    if entry.type == "prompt" then
      table.insert(lines, "")
      table.insert(lines, "❯ " .. entry.text:gsub("\n", "\n  "))
    elseif entry.type == "result" then
      table.insert(lines, "> ✓ " .. entry.text:gsub("\n", "\n> "))
    elseif entry.type == "agent" then
      for _, l in ipairs(vim.split(entry.text, "\n")) do
        table.insert(lines, l)
      end
    end
  end
  return lines
end

-- Public API

function M.setup(user_opts)
  opts = vim.tbl_deep_extend("force", {
    width = 60,
    position = "right",
    chat_height_pct = 60,
  }, user_opts or {})
end

function M.add_prompt(prompt)
  table.insert(state.history, { type = "prompt", text = prompt })
  M.refresh()
end

function M.add_result(text)
  table.insert(state.history, { type = "result", text = text })
  M.refresh()
end

function M.append_agent_text(chunk)
  local last = state.history[#state.history]
  if not last or last.type ~= "agent" then
    table.insert(state.history, { type = "agent", text = chunk })
  else
    last.text = last.text .. chunk
  end
  M.refresh()
end

function M.refresh()
  local sections = { "status", "regions", "context" }
  local renderers = {
    status = render_status,
    regions = render_regions,
    context = render_context,
  }
  for _, key in ipairs(sections) do
    if win_valid(state.wins[key]) then
      local lines, hls = renderers[key]()
      set_buf_content(ensure_buf(key, "lgcc"), lines, hls)
      -- Auto-fit height to content
      vim.api.nvim_win_set_height(state.wins[key], #lines)
    end
  end

  if win_valid(state.wins.chat) then
    local buf = ensure_buf("chat", "markdown")
    local lines = render_chat()
    set_buf_content(buf, lines)
    local lc = vim.api.nvim_buf_line_count(buf)
    pcall(vim.api.nvim_win_set_cursor, state.wins.chat, { lc, 0 })
  end
end

function M.open()
  if win_valid(state.wins.status) then return end

  local prev_win = vim.api.nvim_get_current_win()
  local cmd = opts.position == "left" and "topleft" or "botright"

  -- First split creates the column
  vim.cmd(cmd .. " " .. opts.width .. "vsplit")
  state.wins.status = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.wins.status, ensure_buf("status", "lgcc"))
  set_win_opts(state.wins.status)

  -- Regions
  vim.cmd("belowright 1split")
  state.wins.regions = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.wins.regions, ensure_buf("regions", "lgcc"))
  set_win_opts(state.wins.regions)

  -- Context
  vim.cmd("belowright 1split")
  state.wins.context = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.wins.context, ensure_buf("context", "lgcc"))
  set_win_opts(state.wins.context)

  -- Chat (takes remaining space)
  vim.cmd("belowright split")
  state.wins.chat = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.wins.chat, ensure_buf("chat", "markdown"))
  set_win_opts(state.wins.chat)
  vim.wo[state.wins.chat].winfixheight = false
  vim.wo[state.wins.chat].conceallevel = 2

  M.refresh()

  pcall(vim.api.nvim_set_current_win, prev_win)
end

function M.close()
  for _, key in ipairs({ "chat", "context", "regions", "status" }) do
    if win_valid(state.wins[key]) then vim.api.nvim_win_close(state.wins[key], true) end
    state.wins[key] = nil
  end
end

function M.toggle()
  if win_valid(state.wins.status) then
    M.close()
  else
    M.open()
  end
end

function M.clear_history()
  state.history = {}
  M.refresh()
end

return M
