-- Test auto-paint: run with :luafile lua/lg/test_auto_paint.lua
local server = require("lg.server")
local json = vim.json.encode({
	method = "paint_regions",
	regions = {
		{ file = vim.api.nvim_buf_get_name(0), start_line = 1, end_line = 5 },
		{ file = vim.api.nvim_buf_get_name(0), start_line = 10, end_line = 15 },
	},
})
local result = server.handle_message(json)
print("auto_paint result: " .. result)
