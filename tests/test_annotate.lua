-- Run inside Neovim with :luafile test_annotate.lua
-- Publishes a test annotation at the cursor line via lg-hint.sock (with both message & markdown detail)
-- and adds it to the quickfix list.

local buf = vim.api.nvim_get_current_buf()
local file = vim.api.nvim_buf_get_name(buf)
if file == "" then
	vim.notify("test_annotate: open a file first", vim.log.levels.WARN)
	return
end

local line = vim.api.nvim_win_get_cursor(0)[1]
local line_text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""

local hint = {
	file = file,
	line = line,
	end_line = line,
	column = 1,
	end_column = #line_text + 1,
	message = "Test annotation on line " .. line,
	detail = table.concat({
		"### Test Annotation",
		"",
		"This is a **markdown** hover detail for line `" .. line .. "`.",
		"",
		"---",
		"",
		"```lua",
		"-- Example code block",
		"local ok = true",
		"```",
	}, "\n"),
	severity = "info",
}

local pipe = vim.uv.new_pipe(false)
pipe:connect("/dev/shm/lg-hint.sock", function(err)
	if err then
		pipe:close()
		vim.schedule(function()
			vim.notify("test_annotate: failed to connect to /dev/shm/lg-hint.sock: " .. err, vim.log.levels.ERROR)
		end)
		return
	end
	pipe:write(vim.json.encode({ method = "set_hints", hints = { hint } }) .. "\n", function()
		pipe:read_start(function(rerr, data)
			pipe:close()
			vim.schedule(function()
				if rerr then
					vim.notify("test_annotate: read error: " .. rerr, vim.log.levels.ERROR)
					return
				end
				vim.fn.setqflist({
					{
						bufnr = buf,
						lnum = line,
						col = 1,
						text = "AI - " .. hint.message,
						type = "I",
					},
				}, "a")
				vim.notify("test_annotate: " .. vim.trim(data or "ok") .. " — line " .. line)
			end)
		end)
	end)
end)
