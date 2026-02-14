--- Tests for lg paint + diff (no kiro-cli needed)
--- Run: nvim --headless -u NONE -c "luafile tests/test_paint_diff.lua" -c "qa"

-- Bootstrap: add plugin to runtimepath
local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(plugin_root)

local paint = require("lg.paint")
local diff = require("lg.diff")

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
  return buf
end

print("\n=== lg paint + diff tests ===\n")

test("paint adds region and get_all returns it", function()
  paint.clear()
  local buf = make_buf({ "line1", "line2", "line3" })
  paint.add(buf, 1, 3)
  local regions = paint.get_all()
  assert(#regions == 1, "expected 1 region, got " .. #regions)
  assert(regions[1].bufnr == buf)
  assert(regions[1].start_line == 1)
  assert(regions[1].end_line == 3)
  assert(#regions[1].lines == 3)
  paint.clear()
end)

test("paint multiple regions across buffers", function()
  paint.clear()
  local buf1 = make_buf({ "a", "b", "c" })
  local buf2 = make_buf({ "x", "y", "z" })
  paint.add(buf1, 1, 2)
  paint.add(buf2, 2, 3)
  local regions = paint.get_all()
  assert(#regions == 2, "expected 2 regions, got " .. #regions)
  assert(regions[1].bufnr == buf1)
  assert(regions[2].bufnr == buf2)
  paint.clear()
end)

test("clear_last removes only last region", function()
  paint.clear()
  local buf = make_buf({ "a", "b", "c", "d" })
  paint.add(buf, 1, 2)
  paint.add(buf, 3, 4)
  assert(paint.count() == 2)
  paint.clear_last()
  assert(paint.count() == 1)
  local regions = paint.get_all()
  assert(regions[1].start_line == 1)
  assert(regions[1].end_line == 2)
  paint.clear()
end)

test("diff.apply replaces lines in buffer", function()
  local buf = make_buf({ "old1", "old2", "old3" })
  diff.apply(buf, 0, 2, { "new1", "new2" })
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert(lines[1] == "new1", "expected new1, got " .. lines[1])
  assert(lines[2] == "new2", "expected new2, got " .. lines[2])
  assert(lines[3] == "old3", "expected old3, got " .. lines[3])
end)

test("diff.apply_all edits multiple regions bottom-up", function()
  local buf = make_buf({ "a", "b", "c", "d", "e" })
  local regions = {
    { bufnr = buf, start_line = 1, end_line = 2 },
    { bufnr = buf, start_line = 4, end_line = 5 },
  }
  local edits = {
    { region_id = 0, new_code = "A\nB" },
    { region_id = 1, new_code = "D\nE" },
  }
  diff.apply_all(regions, edits)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert(lines[1] == "A", "expected A, got " .. lines[1])
  assert(lines[2] == "B", "expected B, got " .. lines[2])
  assert(lines[3] == "c", "expected c, got " .. lines[3])
  assert(lines[4] == "D", "expected D, got " .. lines[4])
  assert(lines[5] == "E", "expected E, got " .. lines[5])
end)

test("diff.apply_all handles line count change", function()
  local buf = make_buf({ "a", "b", "c", "d", "e" })
  local regions = {
    { bufnr = buf, start_line = 2, end_line = 3 },
  }
  local edits = {
    { region_id = 0, new_code = "B\nB2\nB3" }, -- 2 lines → 3 lines
  }
  diff.apply_all(regions, edits)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert(#lines == 6, "expected 6 lines, got " .. #lines)
  assert(lines[1] == "a")
  assert(lines[2] == "B")
  assert(lines[3] == "B2")
  assert(lines[4] == "B3")
  assert(lines[5] == "d")
  assert(lines[6] == "e")
end)

test("diff.apply_all handles deletion (fewer lines)", function()
  local buf = make_buf({ "a", "b", "c", "d", "e" })
  local regions = {
    { bufnr = buf, start_line = 2, end_line = 4 },
  }
  local edits = {
    { region_id = 0, new_code = "MERGED" }, -- 3 lines → 1 line
  }
  diff.apply_all(regions, edits)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert(#lines == 3, "expected 3 lines, got " .. #lines)
  assert(lines[1] == "a")
  assert(lines[2] == "MERGED")
  assert(lines[3] == "e")
end)

test("diff.apply_all cross-buffer edits", function()
  local buf1 = make_buf({ "x1", "x2" })
  local buf2 = make_buf({ "y1", "y2" })
  local regions = {
    { bufnr = buf1, start_line = 1, end_line = 1 },
    { bufnr = buf2, start_line = 2, end_line = 2 },
  }
  local edits = {
    { region_id = 0, new_code = "X1_NEW" },
    { region_id = 1, new_code = "Y2_NEW" },
  }
  diff.apply_all(regions, edits)
  assert(vim.api.nvim_buf_get_lines(buf1, 0, -1, false)[1] == "X1_NEW")
  assert(vim.api.nvim_buf_get_lines(buf2, 0, -1, false)[2] == "Y2_NEW")
end)

print(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then vim.cmd("cq") end
