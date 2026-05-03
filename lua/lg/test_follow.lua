--- Manual test: simulate read_buffer with follow highlights
--- Usage: :luafile lua/lg/test_follow.lua
---    or: :lua require("lg.test_follow").read("path/to/file.lua", 5, 15)

local server = require("lg.session.server")
local M = {}

function M.read(path, start_line, end_line)
	path = path or vim.api.nvim_buf_get_name(0)
	start_line = start_line or 1
	end_line = end_line or 20
	server.set_follow_reads(true)
	local result = server.do_read_buffer(vim.fn.fnamemodify(path, ":p"), start_line, end_line)
	local ok, decoded = pcall(vim.json.decode, result)
	if ok and decoded.error then
		vim.notify("read_buffer error: " .. decoded.error, vim.log.levels.ERROR)
	elseif ok then
		vim.notify(string.format("read_buffer: %s [%d-%d of %d]", path, decoded.start_line, decoded.end_line, decoded.total_lines))
	end
end

-- Quick command: :LgTestRead [path] [start] [end]
vim.api.nvim_create_user_command("LgTestRead", function(opts)
	local args = vim.split(opts.args, "%s+")
	local path = args[1] ~= "" and args[1] or nil
	local s = tonumber(args[2])
	local e = tonumber(args[3])
	M.read(path, s, e)
end, { nargs = "*", complete = "file" })

return M
