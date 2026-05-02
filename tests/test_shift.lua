--- Tests for region line numbers after paint_edit
--- Run: nvim --headless -u NONE -c "luafile tests/test_shift.lua" -c "qa"

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(plugin_root)

local paint = require("lg.ui.paint")
local server = require("lg.session.server")

local pass, fail = 0, 0

local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		pass = pass + 1
		print("  ✓ " .. name)
	else
		fail = fail + 1
		print("  ✗ " .. name .. ": " .. tostring(err))
	end
end

local function make_buf(lines)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_name(buf, "/tmp/test_shift_" .. buf .. ".lua")
	return buf
end

print("\n=== Region shift tests ===\n")

-- Simulate: paint lines 5-7, then comment them out (same line count).
-- Region should stay 5-7.
test("comment out (same line count) does not shift region", function()
	paint.clear()
	server.clear_tokens()
	local buf = make_buf({
		"line1", "line2", "line3", "line4",
		"local x = 1",   -- 5
		"local y = 2",   -- 6
		"local z = 3",   -- 7
		"line8", "line9",
	})
	paint.add(buf, 5, 7)

	-- Create token (like send.lua does before prompting)
	local regions = paint.get_all()
	local token = server.create_token(regions)

	-- Simulate paint_edit: comment out lines (same count, no trailing newline)
	local edit_msg = vim.json.encode({
		method = "apply_edits",
		edit_token = token,
		edits = { { region_id = 0, new_code = "-- local x = 1\n-- local y = 2\n-- local z = 3" } },
	})
	local resp = server.handle_message(edit_msg)
	local result = vim.json.decode(resp)
	assert(result.ok, "edit failed: " .. vim.inspect(result))

	-- Check: region should still be 5-7
	local after = paint.get_all()
	assert(#after == 1, "expected 1 region, got " .. #after)
	assert(after[1].start_line == 5, "expected start_line=5, got " .. after[1].start_line)
	assert(after[1].end_line == 7, "expected end_line=7, got " .. after[1].end_line)
	paint.clear()
end)

-- Same but with trailing newline in new_code (what AI often sends)
test("comment out with trailing newline should NOT shift region", function()
	paint.clear()
	server.clear_tokens()
	local buf = make_buf({
		"line1", "line2", "line3", "line4",
		"local x = 1",   -- 5
		"local y = 2",   -- 6
		"local z = 3",   -- 7
		"line8", "line9",
	})
	paint.add(buf, 5, 7)

	local regions = paint.get_all()
	local token = server.create_token(regions)

	-- AI sends trailing newline
	local edit_msg = vim.json.encode({
		method = "apply_edits",
		edit_token = token,
		edits = { { region_id = 0, new_code = "-- local x = 1\n-- local y = 2\n-- local z = 3\n" } },
	})
	local resp = server.handle_message(edit_msg)
	local result = vim.json.decode(resp)
	assert(result.ok, "edit failed: " .. vim.inspect(result))

	-- Buffer should have exactly 9 lines (not 10)
	local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	assert(#buf_lines == 9, "expected 9 buffer lines, got " .. #buf_lines .. " — trailing newline caused extra line")

	-- Check: region should still be 5-7 (NOT 6-8)
	local after = paint.get_all()
	assert(#after == 1, "expected 1 region, got " .. #after)
	assert(after[1].start_line == 5, "expected start_line=5, got " .. after[1].start_line)
	assert(after[1].end_line == 7, "expected end_line=7, got " .. after[1].end_line)
	paint.clear()
end)

-- Region below an edit should shift correctly
test("region below edit shifts by delta", function()
	paint.clear()
	server.clear_tokens()
	local buf = make_buf({
		"local a = 1",   -- 1
		"local b = 2",   -- 2
		"local c = 3",   -- 3
		"",              -- 4
		"local x = 1",  -- 5
		"local y = 2",  -- 6
	})
	paint.add(buf, 1, 2)  -- first region
	paint.add(buf, 5, 6)  -- second region

	local regions = paint.get_all()
	local token = server.create_token(regions)

	-- Edit first region: expand from 2 lines to 3
	local edit_msg = vim.json.encode({
		method = "apply_edits",
		edit_token = token,
		edits = { { region_id = 0, new_code = "local a = 1\nlocal a2 = 11\nlocal b = 2" } },
	})
	server.handle_message(edit_msg)

	-- Second region should shift from 5-6 to 6-7
	local after = paint.get_all()
	assert(#after == 2, "expected 2 regions, got " .. #after)
	assert(after[2].start_line == 6, "expected start_line=6, got " .. after[2].start_line)
	assert(after[2].end_line == 7, "expected end_line=7, got " .. after[2].end_line)
	paint.clear()
end)

print(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then vim.cmd("cq") end
