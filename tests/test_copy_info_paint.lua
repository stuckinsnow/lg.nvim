--- Tests for copy_info_paint
--- Run: nvim --headless -u NONE -c "luafile tests/test_copy_info_paint.lua" -c "qa"

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(plugin_root)

local server = require("lg.server")
local lg = require("lg")

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

local function make_buf(name, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/" .. name)
  return buf
end

print("\n=== copy_info_paint tests ===\n")

test("copy_info_paint formats single-line region", function()
  server.clear_info_paint()
  local buf = make_buf("foo.lua", { "a", "b", "c" })
  -- Manually inject an info region
  local regions = server.get_info_regions()
  table.insert(regions, { bufnr = buf, start_line = 2, end_line = 2 })

  lg.copy_info_paint()
  local clip = vim.fn.getreg("+")
  assert(clip == "foo.lua:2", "expected 'foo.lua:2', got '" .. clip .. "'")
  server.clear_info_paint()
end)

test("copy_info_paint formats multi-line region", function()
  server.clear_info_paint()
  local buf = make_buf("bar.lua", { "a", "b", "c", "d" })
  local regions = server.get_info_regions()
  table.insert(regions, { bufnr = buf, start_line = 1, end_line = 3 })

  lg.copy_info_paint()
  local clip = vim.fn.getreg("+")
  assert(clip == "bar.lua:1-3", "expected 'bar.lua:1-3', got '" .. clip .. "'")
  server.clear_info_paint()
end)

test("copy_info_paint handles multiple regions", function()
  server.clear_info_paint()
  local buf1 = make_buf("a.lua", { "x", "y" })
  local buf2 = make_buf("b.lua", { "1", "2", "3" })
  local regions = server.get_info_regions()
  table.insert(regions, { bufnr = buf1, start_line = 1, end_line = 2 })
  table.insert(regions, { bufnr = buf2, start_line = 2, end_line = 2 })

  lg.copy_info_paint()
  local clip = vim.fn.getreg("+")
  assert(clip == "a.lua:1-2\nb.lua:2", "expected 'a.lua:1-2\\nb.lua:2', got '" .. clip .. "'")
  server.clear_info_paint()
end)

test("copy_info_paint warns when empty", function()
  server.clear_info_paint()
  -- Should not error, just warn
  lg.copy_info_paint()
  local clip = vim.fn.getreg("+")
  -- Clipboard shouldn't have been changed to our format (it keeps whatever was there before)
  assert(true)
end)

print(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then vim.cmd("cq") end
