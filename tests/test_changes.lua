--- Tests for lg.changes (quickfix + gutter highlights)
--- Run: nvim --headless -u NONE -c "luafile tests/test_changes.lua" -c "qa"

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(plugin_root)

local changes = require("lg.changes")

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

local function make_file_buf(path, lines)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local ns = vim.api.nvim_create_namespace("lg_auto_paint")

print("\n=== lg changes tests ===\n")

test("set() adds to quickfix by default", function()
  changes.clear()
  local path = vim.fn.getcwd() .. "/test_qf_default.lua"
  make_file_buf(path, { "line1", "line2", "line3" })

  changes.set({ { file = path, line = 1 } })

  local qf = vim.fn.getqflist()
  assert(#qf == 1, "expected 1 qf item, got " .. #qf)
  changes.clear()
end)

test("set() with skip_qf skips quickfix", function()
  changes.clear()
  local path = vim.fn.getcwd() .. "/test_qf_skip.lua"
  make_file_buf(path, { "line1", "line2", "line3" })

  changes.set({ { file = path, line = 1 } }, { skip_qf = true })

  local qf = vim.fn.getqflist()
  assert(#qf == 0, "expected 0 qf items, got " .. #qf)
  changes.clear()
end)

test("set() with skip_qf still adds gutter extmarks", function()
  changes.clear()
  local path = vim.fn.getcwd() .. "/test_qf_gutter.lua"
  local buf = make_file_buf(path, { "line1", "line2", "line3" })

  changes.set({ { file = path, line = 2 } }, { skip_qf = true })

  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
  assert(#marks > 0, "expected gutter extmarks, got " .. #marks)
  changes.clear()
end)

test("set() without skip_qf adds both quickfix and gutter", function()
  changes.clear()
  local path = vim.fn.getcwd() .. "/test_qf_both.lua"
  local buf = make_file_buf(path, { "line1", "line2", "line3" })

  changes.set({ { file = path, line = 1 } })

  local qf = vim.fn.getqflist()
  assert(#qf == 1, "expected 1 qf item, got " .. #qf)
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
  assert(#marks > 0, "expected gutter extmarks, got " .. #marks)
  changes.clear()
end)

test("clear() removes both quickfix and extmarks", function()
  changes.clear()
  local path = vim.fn.getcwd() .. "/test_qf_clear.lua"
  local buf = make_file_buf(path, { "line1", "line2" })

  changes.set({ { file = path, line = 1 } })
  changes.clear()

  local qf = vim.fn.getqflist()
  assert(#qf == 0, "expected 0 qf items after clear, got " .. #qf)
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
  assert(#marks == 0, "expected 0 extmarks after clear, got " .. #marks)
end)

test("multiple set() calls with mixed skip_qf", function()
  changes.clear()
  local path = vim.fn.getcwd() .. "/test_qf_mixed.lua"
  make_file_buf(path, { "line1", "line2", "line3" })

  changes.set({ { file = path, line = 1 } })           -- adds to qf
  changes.set({ { file = path, line = 2 } }, { skip_qf = true })  -- skips qf

  local qf = vim.fn.getqflist()
  assert(#qf == 1, "expected 1 qf item (only first call), got " .. #qf)
  changes.clear()
end)

print(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then vim.cmd("cq") end
