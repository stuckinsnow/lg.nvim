-- :luafile this from any buffer in nvim
vim.opt.rtp:prepend(vim.fn.expand("~/Dev/development/personal/lg.nvim"))
package.loaded["lg.hunk"] = nil

local hunk = require("lg.hunk")
local buf = vim.api.nvim_get_current_buf()
local path = vim.api.nvim_buf_get_name(buf)
local lines = vim.api.nvim_buf_get_lines(buf, 7, 12, false)
if #lines == 0 then return vim.notify("File has fewer than 12 lines", vim.log.levels.WARN) end

local old = table.concat(lines, "\n")
local new_lines = {}
for _, l in ipairs(lines) do
	new_lines[#new_lines + 1] = l:gsub("(%w+)$", "CHANGED_%1")
end

hunk.propose_edit(path, old, table.concat(new_lines, "\n"))
