--- Window: side column with stacked section windows + interactive markdown chat

local paint = require("lg.ui.paint")
local session = require("lg.session.session")

local M = {}

local PROMPT_MARKER = "❯ "
local INPUT_SEPARATOR = "---"

local state = {
  bufs = {},
  wins = {},
  history = {},
  input_line = nil, -- line number where user input starts
  planner = false,
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
  vim.diagnostic.enable(false, { bufnr = buf })
  return buf
end

local function ensure_buf(key, ft)
  if buf_valid(state.bufs[key]) then return state.bufs[key] end
  state.bufs[key] = make_buf("lg://" .. key, ft)
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
  vim.api.nvim_set_hl(0, "LgTitle", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "LgSeparator", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "LgRegionId", { link = "Number", default = true })
  vim.api.nvim_set_hl(0, "LgFile", { link = "Directory", default = true })
  vim.api.nvim_set_hl(0, "LgStatus", { link = "DiagnosticOk", default = true })
end

local function set_buf_content(buf, lines, hls)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  if hls then
    local ns = vim.api.nvim_create_namespace("lg_" .. buf)
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
  if state.planner then status = status .. "  [PLAN]" end
  return { "Session: " .. status }, { { 0, 0, -1, "LgStatus" } }
end

local function render_regions()
  ensure_highlights()
  local lines = {}
  local hls = {}
  local regions = paint.get_all()
  table.insert(lines, "Editable Regions (" .. #regions .. ")")
  table.insert(hls, { 0, 0, -1, "LgTitle" })
  if #regions == 0 then
    table.insert(lines, "  (none)")
    table.insert(hls, { 1, 0, -1, "LgSeparator" })
  else
    for i, r in ipairs(regions) do
      local fname = r.file ~= "" and vim.fn.fnamemodify(r.file, ":~:.") or "[unnamed]"
      local txt = string.format("  [%d] %s:%d-%d", i - 1, fname, r.start_line, r.end_line)
      table.insert(lines, txt)
      local idx = #lines - 1
      table.insert(hls, { idx, 2, 2 + #tostring(i - 1) + 2, "LgRegionId" })
      table.insert(hls, { idx, 2 + #tostring(i - 1) + 3, -1, "LgFile" })
    end
  end
  return lines, hls
end

local function render_context()
  ensure_highlights()
  local lines = {}
  local hls = {}
  local ctx = require("lg.tools.context").get_all()
  table.insert(lines, "Context (" .. #ctx .. ")")
  table.insert(hls, { 0, 0, -1, "LgTitle" })
  if #ctx == 0 then
    table.insert(lines, "  (none)")
    table.insert(hls, { 1, 0, -1, "LgSeparator" })
  else
    for i, r in ipairs(ctx) do
      local fname = r.file ~= "" and vim.fn.fnamemodify(r.file, ":~:.") or "[unnamed]"
      local header = string.format("  [%d] %s:%d-%d", i - 1, fname, r.start_line, r.end_line)
      if r.label then header = header .. "  search: " .. r.label end
      table.insert(lines, header)
      local idx = #lines - 1
      table.insert(hls, { idx, 2, 2 + #tostring(i - 1) + 2, "LgRegionId" })
      table.insert(hls, { idx, 2 + #tostring(i - 1) + 3, -1, "LgFile" })
      for _, l in ipairs(r.lines or {}) do
        table.insert(lines, "    " .. l)
        table.insert(hls, { #lines - 1, 0, -1, "LgSeparator" })
      end
    end
  end
  local imgs = require("lg.tools.context").get_files()
  for _, img in ipairs(imgs) do
    table.insert(lines, "  📎 " .. vim.fn.fnamemodify(img, ":~:."))
    table.insert(hls, { #lines - 1, 0, -1, "LgFile" })
  end
  local srch = require("lg.tools.context").get_searches()
  for _, s in ipairs(srch) do
    table.insert(lines, string.format('  searched "%s" with nomic-embed-text (%d results)', s.query, #s.results))
    table.insert(hls, { #lines - 1, 0, -1, "LgFile" })
    for _, r in ipairs(s.results) do
      table.insert(lines, string.format("    %.2f  %s:%d-%d", r.score, r.file, r.start_line, r.end_line))
      table.insert(hls, { #lines - 1, 0, -1, "LgSeparator" })
    end
  end
  return lines, hls
end
local function render_chat()
  local lines = {}
  local tool_lines = {}
  for _, entry in ipairs(state.history) do
    if entry.type == "prompt" then
      table.insert(lines, "")
      table.insert(lines, "# Me")
      table.insert(lines, "")
      for _, l in ipairs(vim.split(entry.text, "\n")) do
        table.insert(lines, l)
      end
    elseif entry.type == "result" then
      table.insert(lines, "")
      table.insert(lines, "# AI")
      table.insert(lines, "")
      for _, l in ipairs(vim.split(entry.text, "\n")) do
        table.insert(lines, l)
      end
    elseif entry.type == "agent" then
      if #lines == 0 or lines[#lines] ~= "" then
        table.insert(lines, "")
        table.insert(lines, "# AI")
        table.insert(lines, "")
      end
      for _, l in ipairs(vim.split(entry.text, "\n")) do
        table.insert(lines, l)
      end
    elseif entry.type == "tool" then
      table.insert(lines, "")
      table.insert(lines, "⚙ " .. entry.text)
      tool_lines[#lines] = true
    end
  end
  -- Input area
  table.insert(lines, "")
  table.insert(lines, "# Me")
  table.insert(lines, "")
  state.input_line = #lines -- 0-indexed line where input starts
  table.insert(lines, "")
  return lines, tool_lines
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

function M.get_history()
  local parts = {}
  for _, entry in ipairs(state.history) do
    if entry.type == "prompt" then
      table.insert(parts, "User: " .. entry.text)
    elseif entry.type == "result" or entry.type == "agent" then
      table.insert(parts, "Assistant: " .. entry.text)
    end
  end
  return table.concat(parts, "\n\n")
end

function M.add_result(text)
  table.insert(state.history, { type = "result", text = text })
  M.refresh()
end

function M.add_tool(text)
  table.insert(state.history, { type = "tool", text = text })
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

--- Get user input from the chat buffer and send it
function M.submit()
  local buf = state.bufs.chat
  if not buf_valid(buf) or not state.input_line then return end

  local lines = vim.api.nvim_buf_get_lines(buf, state.input_line, -1, false)
  local text = vim.trim(table.concat(lines, "\n"))
  if text == "" then return end

  -- Include the active file name so the AI knows what the user is looking at
  local active_file
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(win)
    if vim.bo[b].buftype == "" and vim.api.nvim_buf_get_name(b) ~= "" then
      active_file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":~:.")
      break
    end
  end
  if active_file then
    text = "[Current file: " .. active_file .. "]\n" .. text
  end

  require("lg").send({ prompt = text, from_chat = true })
end

--- Focus the chat window input area
function M.focus_input()
  if not win_valid(state.wins.chat) then
    M.open()
  end
  if win_valid(state.wins.chat) then
    vim.api.nvim_set_current_win(state.wins.chat)
    local buf = state.bufs.chat
    if buf_valid(buf) then
      local lc = vim.api.nvim_buf_line_count(buf)
      vim.api.nvim_win_set_cursor(state.wins.chat, { lc, 0 })
      vim.cmd("startinsert!")
    end
  end
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
      set_buf_content(ensure_buf(key, "lg"), lines, hls)
      vim.api.nvim_win_set_height(state.wins[key], #lines)
    end
  end

  if win_valid(state.wins.chat) then
    local buf = ensure_buf("chat", "markdown")
    local lines, tool_lines = render_chat()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local ns = vim.api.nvim_create_namespace("lg_chat")
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for ln in pairs(tool_lines) do
      vim.api.nvim_buf_set_extmark(buf, ns, ln - 1, 0, {
        end_col = #"⚙", hl_group = "LgToolIcon",
      })
      vim.api.nvim_buf_set_extmark(buf, ns, ln - 1, #"⚙", {
        end_row = ln - 1, end_col = #lines[ln], hl_group = "LgTool",
      })
    end
    local lc = vim.api.nvim_buf_line_count(buf)
    pcall(vim.api.nvim_win_set_cursor, state.wins.chat, { lc, 0 })
  end
end

local function setup_chat_keymaps(buf)
  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    M.submit()
  end, { buffer = buf, desc = "Send prompt" })
  vim.keymap.set("n", "<CR>", function()
    M.submit()
  end, { buffer = buf, desc = "Send prompt" })
end

function M.open()
  if win_valid(state.wins.status) then return end

  local prev_win = vim.api.nvim_get_current_win()
  local cmd = opts.position == "left" and "topleft" or "botright"

  vim.cmd(cmd .. " " .. opts.width .. "vsplit")
  state.wins.status = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.wins.status, ensure_buf("status", "lg"))
  set_win_opts(state.wins.status)

  vim.cmd("belowright 1split")
  state.wins.regions = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.wins.regions, ensure_buf("regions", "lg"))
  set_win_opts(state.wins.regions)

  vim.cmd("belowright 1split")
  state.wins.context = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.wins.context, ensure_buf("context", "lg"))
  set_win_opts(state.wins.context)

  vim.cmd("belowright split")
  state.wins.chat = vim.api.nvim_get_current_win()
  local chat_buf = ensure_buf("chat", "markdown")
  vim.api.nvim_win_set_buf(state.wins.chat, chat_buf)
  set_win_opts(state.wins.chat)
  vim.wo[state.wins.chat].winfixheight = false
  vim.wo[state.wins.chat].conceallevel = 2
  vim.bo[chat_buf].modifiable = true

  setup_chat_keymaps(chat_buf)
  M.refresh()

  pcall(vim.api.nvim_set_current_win, state.wins.chat)
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

function M.toggle_planner()
  state.planner = not state.planner
  session.set_planner(state.planner, function(ok)
    if ok then vim.schedule(function() M.refresh() end) end
  end)
end

return M
