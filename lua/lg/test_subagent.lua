local w = require("lg.ui.window")

w.open()

-- Simulate streaming chunks with delays
local chunks = {
  "I'll analyze the code for potential issues.\n\n",
  "Looking at the type definition...\n",
  "Found a **type mismatch** on line 16:\n",
  "`Products` should be `Product` (singular).\n\n",
  "The object structure is correct but the type annotation\n",
  "references a non-existent type.\n\n",
  "Additionally, checking for other issues...\n",
  "- Line 22: unused import `useState`\n",
  "- Line 35: missing null check on `response.data`\n",
  "- Line 41: `async` function without `await`\n",
  "- Line 58: potential memory leak in `useEffect`\n",
  "- Line 63: hardcoded API URL should use env var\n",
  "- Line 71: `any` type should be narrowed\n",
  "- Line 80: missing error boundary\n",
  "- Line 92: deprecated `componentWillMount` usage\n",
  "- Line 105: unhandled promise rejection\n",
}

local i = 0
local timer = vim.uv.new_timer()
timer:start(200, 300, vim.schedule_wrap(function()
  i = i + 1
  if i <= #chunks then
    w.append_subagent_text(chunks[i])
  else
    timer:stop()
    timer:close()
    w.finish_subagent()
  end
end))
