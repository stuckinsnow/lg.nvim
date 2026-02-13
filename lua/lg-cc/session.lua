--- Session: manages a persistent kiro-cli ACP subprocess
--- Handles: spawn, initialize, session/new, session/prompt lifecycle.

local protocol = require("lg-cc.protocol")

local M = {}

--- @class LgCC.Session
--- @field proc vim.SystemObj?
--- @field next_id number
--- @field pending table<number, {result:any, error:any}?>
--- @field session_id string?
--- @field stdout_buf string

--- @type LgCC.Session?
local state = nil
local opts = {}

function M.setup(user_opts)
  opts = vim.tbl_deep_extend("force", {
    cmd = { "kiro-cli", "acp" },
    timeout = 30000,
    mcp_servers = {},
  }, user_opts or {})
end

--- @param s LgCC.Session
--- @param msg table
local function write(s, msg)
  if s.proc then
    s.proc:write(vim.json.encode(msg) .. "\n")
  end
end

--- Send request and busy-wait for response
--- @param s LgCC.Session
--- @param method string
--- @param params table
--- @return table?
local function rpc_request(s, method, params)
  local id = s.next_id
  s.next_id = id + 1
  write(s, { jsonrpc = "2.0", id = id, method = method, params = params or {} })

  local start = vim.uv.hrtime()
  local timeout_ns = opts.timeout * 1e6
  while vim.uv.hrtime() - start < timeout_ns do
    vim.wait(10)
    if s.pending[id] then
      local resp = s.pending[id]
      s.pending[id] = nil
      if resp.error then
        vim.notify("lg-cc: " .. method .. " error: " .. vim.inspect(resp.error), vim.log.levels.ERROR)
        return nil
      end
      return resp.result
    end
  end
  vim.notify("lg-cc: " .. method .. " timed out", vim.log.levels.ERROR)
  return nil
end

--- Handle a parsed JSON-RPC message
--- @param s LgCC.Session
--- @param msg table
local function handle_message(s, msg)
  -- Response to our request
  if msg.id and not msg.method then
    s.pending[msg.id] = { result = msg.result, error = msg.error }

    -- Check if prompt completed (has stopReason)
    if msg.result and msg.result.stopReason then
      vim.schedule(function()
        vim.notify("lg-cc: turn complete (" .. msg.result.stopReason .. ")", vim.log.levels.INFO)
      end)
    end
    return
  end

  -- Notifications from agent
  local method = msg.method or ""

  if method == "session/update" then
    local update = msg.params and msg.params.update
    if update then
      if update.sessionUpdate == "agent_message_chunk" then
        -- Streaming text from agent (could show in window later)
      elseif update.sessionUpdate == "tool_call" then
        vim.schedule(function()
          local title = update.title or update.toolCallId or "unknown"
          vim.notify("lg-cc: tool call — " .. title, vim.log.levels.INFO)
        end)
      end
    end

  elseif method == "session/request_permission" then
    -- Auto-approve everything
    local tool_options = msg.params and msg.params.options or {}
    local option_id
    for _, opt in ipairs(tool_options) do
      if opt.kind == "allow_always" or opt.kind == "allow_once" then
        option_id = opt.optionId
        break
      end
    end
    option_id = option_id or (tool_options[1] and tool_options[1].optionId)

    if option_id and msg.id then
      vim.schedule(function()
        local tc = msg.params and msg.params.toolCall
        local title = tc and tc.title or "permission"
        vim.notify("lg-cc: auto-approved — " .. title, vim.log.levels.INFO)
      end)
      write(s, {
        jsonrpc = "2.0",
        id = msg.id,
        result = { outcome = { outcome = "selected", optionId = option_id } },
      })
    end

  elseif method == "fs/read_text_file" then
    local path = msg.params and msg.params.path
    if path and msg.id then
      local content = ""
      local f = io.open(path, "r")
      if f then content = f:read("*a"); f:close() end
      write(s, { jsonrpc = "2.0", id = msg.id, result = { content = content } })
    end

  elseif method == "fs/write_text_file" then
    local path = msg.params and msg.params.path
    local content = msg.params and msg.params.content or ""
    if path and msg.id then
      vim.schedule(function()
        vim.notify("lg-cc: writing " .. vim.fn.fnamemodify(path, ":~:."), vim.log.levels.INFO)
      end)
      local f = io.open(path, "w")
      if f then f:write(content); f:close() end
      write(s, { jsonrpc = "2.0", id = msg.id, result = vim.NIL })
      -- Reload buffer if open
      vim.schedule(function()
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == path then
            vim.api.nvim_buf_call(buf, function() vim.cmd("edit!") end)
          end
        end
      end)
    end

  -- Ignore kiro-internal notifications
  elseif method:match("^_kiro") then
    -- silently ignore
  end
end

--- Buffer stdout and dispatch
--- @param s LgCC.Session
--- @param data string
local function on_stdout(s, data)
  s.stdout_buf = s.stdout_buf .. data
  while true do
    local nl = s.stdout_buf:find("\n")
    if not nl then break end
    local line = s.stdout_buf:sub(1, nl - 1):gsub("\r$", "")
    s.stdout_buf = s.stdout_buf:sub(nl + 1)
    if line ~= "" and line:match("^%s*{") then
      local ok, msg = pcall(vim.json.decode, line)
      if ok then handle_message(s, msg) end
    end
  end
end

--- Spawn kiro-cli and establish session
--- @return LgCC.Session?
local function connect()
  if state and state.proc then return state end

  vim.notify("lg-cc: starting kiro-cli...", vim.log.levels.INFO)

  local s = {
    proc = nil,
    next_id = 1,
    pending = {},
    session_id = nil,
    stdout_buf = "",
    models = nil,
  }

  local proc = vim.system(opts.cmd, {
    stdin = true,
    cwd = vim.fn.getcwd(),
    stdout = vim.schedule_wrap(function(_, data)
      if data then on_stdout(s, data) end
    end),
    stderr = vim.schedule_wrap(function(_, data) end),
  }, vim.schedule_wrap(function(_)
    s.proc = nil
    s.session_id = nil
  end))

  s.proc = proc
  state = s

  -- Initialize
  local init = rpc_request(s, "initialize", {
    protocolVersion = 1,
    clientCapabilities = { fs = { readTextFile = true, writeTextFile = true } },
    clientInfo = { name = "lg-cc", version = "2.0.0" },
  })
  if not init then
    M.clear()
    return nil
  end
  vim.notify("lg-cc: initialized (agent: " .. (init.agentInfo and init.agentInfo.name or "?") .. ")", vim.log.levels.INFO)

  -- Session new (mcpServers must be an array!)
  local session_result = rpc_request(s, "session/new", {
    cwd = vim.fn.getcwd(),
    mcpServers = opts.mcp_servers,
  })
  if not session_result or not session_result.sessionId then
    vim.notify("lg-cc: failed to create session", vim.log.levels.ERROR)
    M.clear()
    return nil
  end
  s.session_id = session_result.sessionId
  s.models = session_result.models
  vim.notify("lg-cc: session ready", vim.log.levels.INFO)

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("lgcc_session", { clear = true }),
    callback = function() M.clear() end,
  })

  return s
end

--- Send a prompt with painted regions
--- @param prompt string
--- @param regions table[]
function M.send(prompt, regions)
  local s = connect()
  if not s then return end

  local messages = protocol.build_prompt(regions, prompt)

  vim.notify("lg-cc: sending prompt...", vim.log.levels.INFO)

  -- Async: send prompt, don't block
  local id = s.next_id
  s.next_id = id + 1
  write(s, {
    jsonrpc = "2.0",
    id = id,
    method = "session/prompt",
    params = { sessionId = s.session_id, prompt = messages },
  })
end

function M.clear()
  if not state then return end
  if state.proc then
    pcall(function() state.proc:kill(9) end)
  end
  state = nil
  vim.notify("lg-cc: session cleared", vim.log.levels.INFO)
end

--- @return boolean
function M.is_active()
  return state ~= nil and state.proc ~= nil
end

--- Select model via vim.ui.select (uses ACP's model list)
function M.select_model()
  local s = connect()
  if not s or not s.models then
    vim.notify("lg-cc: no models available", vim.log.levels.WARN)
    return
  end

  local names = {}
  for _, m in ipairs(s.models.availableModels or {}) do
    local label = m.modelId
    if m.modelId == s.models.currentModelId then
      label = label .. " (current)"
    end
    table.insert(names, label)
  end

  vim.ui.select(names, { prompt = "lg-cc model:" }, function(choice)
    if not choice then return end
    local model_id = choice:gsub(" %(current%)$", "")
    -- Send session/set_model
    local id = s.next_id
    s.next_id = id + 1
    write(s, {
      jsonrpc = "2.0",
      id = id,
      method = "session/set_model",
      params = { sessionId = s.session_id, modelId = model_id },
    })
    s.models.currentModelId = model_id
    vim.notify("lg-cc: model → " .. model_id, vim.log.levels.INFO)
  end)
end

--- @return string? current model id
function M.current_model()
  if state and state.models then
    return state.models.currentModelId
  end
  return nil
end

return M
