--- lg-cc: Paint regions for constrained AI editing via CodeCompanion
--- Provides visual region painting + a CodeCompanion tool that only allows
--- editing within painted areas.

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
