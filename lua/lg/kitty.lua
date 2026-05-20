--- Kitty terminal progress bar via OSC 9;4
local M = {}

local function write(s)
  local tty = vim.uv.new_tty(1, false)
  if tty then
    tty:write(s)
    tty:close()
  end
end

--- Set progress bar (0-100)
function M.set(pct)
  local n = math.floor(math.max(0, math.min(100, pct)))
  write(string.format("\027]9;4;1;%d\027\\", n))
end

--- Clear progress bar
function M.clear()
  write("\027]9;4;0\027\\")
end

return M
