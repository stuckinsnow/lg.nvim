--- Test: multi-region edit applies correctly without relying on AI ordering
--- Run with: nvim --headless -u NONE -l tests/test_multi_edit.lua

-- Bootstrap: add plugin to runtimepath
local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(plugin_root)

local paint = require("lg-cc.paint")
local diff = require("lg-cc.diff")

local pass = 0
local fail = 0

local function assert_eq(label, got, expected)
  if type(got) == "table" and type(expected) == "table" then
    got = table.concat(got, "\n")
    expected = table.concat(expected, "\n")
  end
  if got == expected then
    pass = pass + 1
    print("  PASS: " .. label)
  else
    fail = fail + 1
    print("  FAIL: " .. label)
    print("    expected: " .. tostring(expected))
    print("    got:      " .. tostring(got))
  end
end

local function make_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local function get_lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

--- apply_all: given a list of {region_id, new_code}, applies all edits
--- This is the function we're testing — it must handle ordering internally
local function apply_all(edits)
  local regions = paint.get_all()
  diff.apply_all(regions, edits)
end

-- ============================================================
print("Test 1: Two regions, same line count, reverse order")
-- ============================================================
do
  paint.clear()
  local buf = make_buf({
    "line 1",    -- 1
    "line 2",    -- 2  <- region 0
    "line 3",    -- 3  <- region 0
    "line 4",    -- 4
    "line 5",    -- 5  <- region 1
    "line 6",    -- 6  <- region 1
    "line 7",    -- 7
  })
  paint.add(buf, 2, 3)  -- region 0: lines 2-3
  paint.add(buf, 5, 6)  -- region 1: lines 5-6

  apply_all({
    { region_id = 0, new_code = "-- line 2\n-- line 3" },
    { region_id = 1, new_code = "-- line 5\n-- line 6" },
  })

  assert_eq("all lines correct", get_lines(buf), {
    "line 1",
    "-- line 2",
    "-- line 3",
    "line 4",
    "-- line 5",
    "-- line 6",
    "line 7",
  })
end

-- ============================================================
print("Test 2: Region 1 grows (adds lines), region 0 still correct")
-- ============================================================
do
  paint.clear()
  local buf = make_buf({
    "aaa",    -- 1
    "bbb",    -- 2  <- region 0
    "ccc",    -- 3
    "ddd",    -- 4  <- region 1
    "eee",    -- 5
  })
  paint.add(buf, 2, 2)  -- region 0: line 2
  paint.add(buf, 4, 4)  -- region 1: line 4

  apply_all({
    { region_id = 0, new_code = "-- bbb" },
    { region_id = 1, new_code = "-- ddd line1\n-- ddd line2\n-- ddd line3" },
  })

  assert_eq("region 1 grew, region 0 untouched", get_lines(buf), {
    "aaa",
    "-- bbb",
    "ccc",
    "-- ddd line1",
    "-- ddd line2",
    "-- ddd line3",
    "eee",
  })
end

-- ============================================================
print("Test 3: Region 0 grows, region 1 still correct")
-- ============================================================
do
  paint.clear()
  local buf = make_buf({
    "aaa",    -- 1
    "bbb",    -- 2  <- region 0
    "ccc",    -- 3
    "ddd",    -- 4  <- region 1
    "eee",    -- 5
  })
  paint.add(buf, 2, 2)  -- region 0: line 2
  paint.add(buf, 4, 4)  -- region 1: line 4

  apply_all({
    { region_id = 0, new_code = "-- bbb1\n-- bbb2\n-- bbb3" },
    { region_id = 1, new_code = "-- ddd" },
  })

  assert_eq("region 0 grew, region 1 correct", get_lines(buf), {
    "aaa",
    "-- bbb1",
    "-- bbb2",
    "-- bbb3",
    "ccc",
    "-- ddd",
    "eee",
  })
end

-- ============================================================
print("Test 4: Region 1 shrinks (removes lines)")
-- ============================================================
do
  paint.clear()
  local buf = make_buf({
    "aaa",    -- 1
    "bbb",    -- 2  <- region 0
    "ccc",    -- 3
    "ddd",    -- 4  <- region 1
    "eee",    -- 5  <- region 1
    "fff",    -- 6  <- region 1
    "ggg",    -- 7
  })
  paint.add(buf, 2, 2)  -- region 0: line 2
  paint.add(buf, 4, 6)  -- region 1: lines 4-6

  apply_all({
    { region_id = 0, new_code = "-- bbb" },
    { region_id = 1, new_code = "-- combined" },
  })

  assert_eq("region 1 shrank", get_lines(buf), {
    "aaa",
    "-- bbb",
    "ccc",
    "-- combined",
    "ggg",
  })
end

-- ============================================================
print("Test 5: Three regions, middle one grows")
-- ============================================================
do
  paint.clear()
  local buf = make_buf({
    "1",      -- 1
    "2",      -- 2  <- region 0
    "3",      -- 3
    "4",      -- 4  <- region 1
    "5",      -- 5
    "6",      -- 6  <- region 2
    "7",      -- 7
  })
  paint.add(buf, 2, 2)  -- region 0
  paint.add(buf, 4, 4)  -- region 1
  paint.add(buf, 6, 6)  -- region 2

  apply_all({
    { region_id = 0, new_code = "-- 2" },
    { region_id = 1, new_code = "-- 4a\n-- 4b\n-- 4c" },
    { region_id = 2, new_code = "-- 6" },
  })

  assert_eq("three regions, middle grew", get_lines(buf), {
    "1",
    "-- 2",
    "3",
    "-- 4a",
    "-- 4b",
    "-- 4c",
    "5",
    "-- 6",
    "7",
  })
end

-- ============================================================
print("")
print(string.format("Results: %d passed, %d failed", pass, fail))
if fail > 0 then
  vim.cmd("cquit! 1")
else
  vim.cmd("qall!")
end
