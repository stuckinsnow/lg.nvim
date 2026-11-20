-- Interactive spinner tester: run with :luafile lua/lg/test_spinners.lua
-- Uses your currently painted regions, or temporarily paints lines around the cursor.

local spinners = require("lg.spinner.spinners")
local paint = require("lg.ui.paint")

local types = { "hint", "wave", "block", "center", "sign" }
local items = {
	"hint   — '⠋ AI is processing' once at top of region",
	"wave   — cycling text color down the lines",
	"block  — animated diagonal overlay box",
	"center — braille + 'Processing' centered overlay",
	"sign   — pulsing gutter bracket signs (requires paint.signs = true)",
	"cycle all (3s each)",
	"stop",
}

local function get_regions()
	local regions = paint.get_all()
	if #regions > 0 then
		return regions, false
	end
	local buf = vim.api.nvim_get_current_buf()
	local cur = vim.api.nvim_win_get_cursor(0)[1]
	local total = vim.api.nvim_buf_line_count(buf)
	local s = math.max(1, cur)
	local e = math.min(total, cur + 8)
	paint.add(buf, s, e)
	return paint.get_all(), true
end

local function cleanup(temp_painted)
	spinners.stop()
	if temp_painted then
		paint.clear_last()
	end
end

local function run_one(name, duration_ms, on_done)
	local regions, temp_painted = get_regions()
	spinners.stop()
	spinners.setup({ spinner_type = name })
	local handle = spinners.start(regions)
	vim.notify("lg spinner: " .. name, vim.log.levels.INFO)
	vim.defer_fn(function()
		handle.stop()
		if temp_painted then
			paint.clear_last()
		end
		if on_done then
			on_done()
		end
	end, duration_ms)
end

local function run_cycle()
	local regions, temp_painted = get_regions()
	local idx = 1
	local function next_spinner()
		spinners.stop()
		if idx > #types then
			cleanup(temp_painted)
			vim.notify("lg spinner test done", vim.log.levels.INFO)
			return
		end
		local name = types[idx]
		idx = idx + 1
		spinners.setup({ spinner_type = name })
		spinners.start(regions)
		vim.notify("lg spinner (" .. (idx - 1) .. "/" .. #types .. "): " .. name, vim.log.levels.INFO)
		vim.defer_fn(next_spinner, 3000)
	end
	next_spinner()
end

vim.ui.select(items, { prompt = "Test lg spinner:" }, function(_, idx)
	if not idx then
		return
	end
	if idx == #items then
		spinners.stop()
		vim.notify("lg spinner stopped", vim.log.levels.INFO)
	elseif idx == #items - 1 then
		run_cycle()
	else
		run_one(types[idx], 4000)
	end
end)
