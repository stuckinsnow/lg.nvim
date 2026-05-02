--- Test for stray sign extmarks after paint_edit
--- Run: nvim --headless -u NONE -c "luafile tests/test_stray_sign.lua" -c "qa"

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(plugin_root)

local paint = require("lg.ui.paint")
local diff = require("lg.ui.diff")

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
	vim.api.nvim_buf_set_name(buf, "/tmp/test_stray_" .. buf .. ".lua")
	return buf
end

local function get_all_signs(bufnr)
	local signs = {}
	local paint_ns = vim.api.nvim_create_namespace("lg.ui.paint")
	local diff_ns = vim.api.nvim_create_namespace("lg_marks")
	local ns_names = { [paint_ns] = "paint", [diff_ns] = "diff" }
	for _, ns_id in ipairs({ paint_ns, diff_ns }) do
		local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, { details = true })
		for _, m in ipairs(marks) do
			if m[4] and m[4].sign_text then
				table.insert(signs, { row = m[2], sign = m[4].sign_text, ns_name = ns_names[ns_id] })
			end
		end
	end
	return signs
end

print("\n=== Stray sign tests ===\n")

test("no signs outside painted region after edit (same line count)", function()
	paint.clear()
	local buf = make_buf({
		"line1", "line2", "line3", "line4",
		"local x = 1",   -- 5
		"local y = 2",   -- 6
		"local z = 3",   -- 7
		"line8", "line9", "line10",
	})
	paint.add(buf, 5, 7)

	-- Simulate edit: comment out (same line count)
	diff.apply(buf, 4, 7, { "-- local x = 1", "-- local y = 2", "-- local z = 3" })

	local signs = get_all_signs(buf)
	for _, s in ipairs(signs) do
		-- All signs must be within rows 4-6 (0-indexed for lines 5-7)
		assert(s.row >= 4 and s.row <= 6,
			string.format("stray sign '%s' at row %d (expected 4-6)", s.sign, s.row))
	end
	paint.clear()
end)

test("no signs outside painted region after edit (more lines)", function()
	paint.clear()
	local buf = make_buf({
		"line1", "line2", "line3", "line4",
		"local x = 1",   -- 5
		"local y = 2",   -- 6
		"local z = 3",   -- 7
		"line8", "line9", "line10",
	})
	paint.add(buf, 5, 7)

	-- Simulate edit: expand from 3 to 4 lines
	diff.apply(buf, 4, 7, { "-- local x = 1", "-- local y = 2", "-- local z = 3", "-- extra" })
	paint.shift_after(buf, 5, 1)

	local signs = get_all_signs(buf)
	for _, s in ipairs(signs) do
		-- Paint region is now 5-7 still (shift_after only shifts regions BELOW edit_start)
		-- But the buffer has an extra line. Signs should be within 4-7 (0-indexed)
		assert(s.row >= 4 and s.row <= 7,
			string.format("stray sign '%s' at row %d (expected 4-7)", s.sign, s.row))
	end
	paint.clear()
end)

test("no signs outside painted region after edit (fewer lines)", function()
	paint.clear()
	local buf = make_buf({
		"line1", "line2", "line3", "line4",
		"local x = 1",   -- 5
		"local y = 2",   -- 6
		"local z = 3",   -- 7
		"line8", "line9", "line10",
	})
	paint.add(buf, 5, 7)

	-- Simulate edit: shrink from 3 to 2 lines
	diff.apply(buf, 4, 7, { "-- merged1", "-- merged2" })

	local signs = get_all_signs(buf)
	for _, s in ipairs(signs) do
		assert(s.row >= 4 and s.row <= 6,
			string.format("stray sign '%s' at row %d (expected 4-6)", s.sign, s.row))
	end
	paint.clear()
end)

print(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then vim.cmd("cq") end
