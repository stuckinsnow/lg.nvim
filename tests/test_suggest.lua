-- Run inside Neovim with :luafile tests/test_suggest.lua
-- Publishes a test suggestion with a `replacement` at the cursor line via lg-hint.sock
-- Hover with K to preview, or press gra to apply the code action.

local buf = vim.api.nvim_get_current_buf()
local file = vim.api.nvim_buf_get_name(buf)
if file == "" then
	vim.notify("test_suggest: open a file first", vim.log.levels.WARN)
	return
end

local line = vim.api.nvim_win_get_cursor(0)[1]
local line_text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
local replacement = line_text .. " -- suggested edit"

local hint = {
	file = file,
	line = line,
	end_line = line,
	column = 1,
	end_column = #line_text + 1,
	message = "Test suggestion on line " .. line,
	detail = table.concat({
		"### Test Suggestion",
		"",
		"Press `gra` and choose **Apply** to replace line `" .. line .. "`:",
		"",
		"```",
		replacement,
		"```",
	}, "\n"),
	replacement = replacement,
	severity = "hint",
}

local pipe = vim.uv.new_pipe(false)
pipe:connect("/dev/shm/lg-hint.sock", function(err)
	if err then
		pipe:close()
		vim.schedule(function()
			vim.notify("test_suggest: failed to connect to /dev/shm/lg-hint.sock: " .. err, vim.log.levels.ERROR)
		end)
		return
	end
	pipe:write(vim.json.encode({ method = "set_hints", hints = { hint } }) .. "\n", function()
		pipe:read_start(function(rerr, data)
			pipe:close()
			vim.schedule(function()
				if rerr then
					vim.notify("test_suggest: read error: " .. rerr, vim.log.levels.ERROR)
					return
				end
				vim.notify("test_suggest: " .. vim.trim(data or "ok") .. " — line " .. line .. " (try K or gra)")
			end)
		end)
	end)
end)
