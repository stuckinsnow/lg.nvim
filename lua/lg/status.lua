--- Noice status: spinner + progress notifications via noice.nvim

local M = {}

--- @type table? active noice message
local active = nil

local function has_noice()
  return pcall(require, "noice.message")
end

local function update_loop()
  if not active or active.stopped then return end
  local Format = require("noice.text.format")
  local Manager = require("noice.message.manager")
  Manager.add(Format.format(active.message, "lsp_progress"))
  vim.defer_fn(update_loop, 200)
end

--- Start spinner with initial message
--- @param text? string
function M.start(text)
  if not has_noice() then return end
  M.stop()

  local Message = require("noice.message")
  local msg = Message("lsp", "progress")
  msg.opts.progress = {
    client_id = "lg_" .. vim.uv.hrtime(),
    client = "lg",
    id = vim.uv.hrtime(),
    message = text or "Processing...",
  }

  active = { message = msg, stopped = false }
  update_loop()
end

--- Update spinner text
--- @param text string
function M.update(text)
  if not active or active.stopped then return end
  active.message.opts.progress.message = text
end

--- Stop spinner with final message
--- @param text? string
function M.stop(text)
  if not active or not has_noice() then return end
  active.stopped = true
  active.message.opts.progress.message = text or "Done"

  local Format = require("noice.text.format")
  local Manager = require("noice.message.manager")
  local Router = require("noice.message.router")
  Manager.add(Format.format(active.message, "lsp_progress"))
  Router.update()

  local msg = active.message
  active = nil
  vim.defer_fn(function()
    Manager.remove(msg)
  end, 2000)
end

--- Show a brief standalone noice message (stacks alongside active spinner)
--- @param text string
--- @param ms? number display duration (default 3000)
function M.flash(text, ms)
  if not has_noice() then return end
  local Message = require("noice.message")
  local Format = require("noice.text.format")
  local Manager = require("noice.message.manager")
  local m = Message("lsp", "progress")
  m.opts.progress = { client_id = "lg_flash", client = "lg", id = vim.uv.hrtime(), message = text }
  Manager.add(Format.format(m, "lsp_progress"))
  vim.defer_fn(function() Manager.remove(m) end, ms or 3000)
end

return M
