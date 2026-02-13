--- lg-cc: Paint regions for constrained AI editing via kiro-cli ACP

if vim.g.loaded_lg_cc then return end
vim.g.loaded_lg_cc = true

vim.api.nvim_create_user_command("LgCCPaint", function()
  require("lg-cc").paint()
end, { range = true, desc = "Paint visual selection as editable region" })

vim.api.nvim_create_user_command("LgCCClear", function()
  require("lg-cc").clear()
end, { desc = "Clear all painted regions" })

vim.api.nvim_create_user_command("LgCCClearLast", function()
  require("lg-cc").clear_last()
end, { desc = "Clear last painted region" })

vim.api.nvim_create_user_command("LgCCSend", function(cmd_opts)
  local prompt = cmd_opts.args ~= "" and cmd_opts.args or nil
  require("lg-cc").send({ prompt = prompt })
end, { nargs = "?", desc = "Send painted regions to kiro-cli" })

vim.api.nvim_create_user_command("LgCCClearSession", function()
  require("lg-cc").clear_session()
end, { desc = "Clear kiro-cli session (start fresh)" })

vim.api.nvim_create_user_command("LgCCContext", function()
  require("lg-cc").context_paint()
end, { range = true, desc = "Paint visual selection as read-only context" })

vim.api.nvim_create_user_command("LgCCClearContext", function()
  require("lg-cc").clear_context()
end, { desc = "Clear all context regions" })

vim.api.nvim_create_user_command("LgCCClearAll", function()
  require("lg-cc").clear_all()
end, { desc = "Clear all paint + context" })

vim.api.nvim_create_user_command("LgCCToggle", function()
  require("lg-cc").toggle_window()
end, { desc = "Toggle lg-cc side panel" })
