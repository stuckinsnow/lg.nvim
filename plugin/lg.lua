--- lg: Paint regions for constrained AI editing via kiro-cli ACP

if vim.g.loaded_lg then return end
vim.g.loaded_lg = true

vim.api.nvim_create_user_command("LgPaint", function()
  require("lg").paint()
end, { range = true, desc = "Paint visual selection as editable region" })

vim.api.nvim_create_user_command("LgClear", function()
  require("lg").clear()
end, { desc = "Clear all painted regions" })

vim.api.nvim_create_user_command("LgClearLast", function()
  require("lg").clear_last()
end, { desc = "Clear last painted region" })

vim.api.nvim_create_user_command("LgSend", function(cmd_opts)
  local prompt = cmd_opts.args ~= "" and cmd_opts.args or nil
  require("lg").send({ prompt = prompt })
end, { nargs = "?", desc = "Send painted regions to kiro-cli" })

vim.api.nvim_create_user_command("LgClearSession", function()
  require("lg").clear_session()
end, { desc = "Clear kiro-cli session (start fresh)" })

vim.api.nvim_create_user_command("LgContext", function()
  require("lg").context_paint()
end, { range = true, desc = "Paint visual selection as read-only context" })

vim.api.nvim_create_user_command("LgClearContext", function()
  require("lg").clear_context()
end, { desc = "Clear all context regions" })

vim.api.nvim_create_user_command("LgClearAll", function()
  require("lg").clear_all()
end, { desc = "Clear all paint + context" })

vim.api.nvim_create_user_command("LgToggle", function()
  require("lg").toggle_window()
end, { desc = "Toggle lg side panel" })

vim.api.nvim_create_user_command("LgTestChat", function()
  local w = require("lg.window")
  w.add_prompt("is this code ok?")
  w.append_agent_text("Yes! Here's a fix:\n\n```lua\nlocal function hello()\n  print('world')\nend\n```\n\nThat should work.")
  w.add_result("Applied 1 edit")
  w.add_prompt("now make it async")
  w.append_agent_text("Sure:\n\n```lua\nvim.schedule(function()\n  print('async world')\nend)\n```")
end, { desc = "Fill chat with test data" })

vim.api.nvim_create_user_command("LgQuickEdit", function()
  require("lg").quick_edit()
end, { range = true, desc = "Quick edit: paint + prompt + isolated session" })
