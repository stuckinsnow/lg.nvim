--- Confirmed ACP model selection.
---
--- OpenCode can advertise an incomplete model list and later replace it through
--- config_option_update.  A set_model acknowledgement alone is therefore not
--- sufficient: wait until the requested model is advertised and confirmed.

local client = require("lg.session.client")

local M = {}

local function cleanup(state)
  if state.unsubscribe_changed then state.unsubscribe_changed() end
  if state.unsubscribe_models then state.unsubscribe_models() end
  if state.timer then state.timer:stop(); state.timer:close() end
end

function M.set_confirmed(session_id, model_id, opts)
  opts = opts or {}
  local timeout_ms = opts.timeout_ms or 5000
  local state = {
    finished = false,
    request_pending = false,
  }

  local function finish(ok)
    if state.finished then return end
    state.finished = true
    cleanup(state)
    if opts.on_done then opts.on_done(ok) end
  end

  local function config_confirms_model(config_options)
    for _, option in ipairs(config_options or {}) do
      if option.id == "model" then
        return option.currentValue == model_id
      end
    end
    return false
  end

  local function request_model()
    if state.finished or state.request_pending then return end
    state.request_pending = true
    client.set_model(session_id, model_id, function(resp)
      state.request_pending = false
      if resp and resp.ok == true then
        if config_confirms_model(resp.data and resp.data.configOptions) then
          finish(true)
        end
      elseif resp and resp.error then
        if not tostring(resp.error):find("model not found", 1, true) then
          finish(false)
        end
      end
    end)
  end

  state.unsubscribe_changed = client.on("model_changed", function(ev)
    if ev.session_id == session_id and ev.text == model_id then
      finish(true)
    end
  end)

  state.unsubscribe_models = client.on("models_updated", function(ev)
    if ev.session_id ~= session_id or type(ev.data) ~= "table" then return end

    local config_options = ev.data.configOptions or {}
    if config_confirms_model(config_options) then
      finish(true)
      return
    end

    for _, option in ipairs(config_options) do
      if option.id == "model" then
        for _, candidate in ipairs(option.options or {}) do
          if candidate.value == model_id then
            request_model()
            return
          end
        end
      end
    end
  end)

  request_model()

  state.timer = vim.uv.new_timer()
  if state.timer then
    state.timer:start(timeout_ms, 0, vim.schedule_wrap(function()
      finish(false)
    end))
  end

  return function()
    finish(false)
  end
end

return M
