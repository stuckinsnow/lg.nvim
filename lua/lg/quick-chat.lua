--- Chat: visual selection → chat-only prompt (no editing allowed)

local session = require("lg.session")
local window = require("lg.window")
local status = require("lg.status")

local M = {}

function M.quick_chat()
	local buf = vim.api.nvim_get_current_buf()
	local s = vim.fn.getpos("'<")
	local e = vim.fn.getpos("'>")
	local lines = vim.api.nvim_buf_get_lines(buf, s[2] - 1, e[2], false)
	local fname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":~:.")
	local snippet = string.format("%s lines %d–%d:\n```\n%s\n```", fname, s[2], e[2], table.concat(lines, "\n"))

	require("lg.prompt").open(function(prompt)
		if not prompt or prompt == "" then return end
		local full = "You are in chat-only mode. Do NOT edit any code or use any editing tools. Just answer the question.\n\nCode snippet:\n"
			.. snippet .. "\n\n" .. prompt
		window.add_prompt(prompt)
		window.open()
		status.start("Thinking...")
		session.send(full, {}, {}, function()
			vim.schedule(function() status.stop() end)
		end)
	end)
end

return M
