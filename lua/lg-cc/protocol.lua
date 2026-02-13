--- Protocol: builds ACP prompt messages from painted regions

local M = {}

--- Build the prompt content array for session/prompt
--- @param regions table[] from paint.get_all()
--- @param user_prompt string
--- @return table[] ACP prompt content blocks
function M.build_prompt(regions, user_prompt)
  local parts = {}

  -- System context: describe painted regions
  if #regions > 0 then
    local ctx = {
      "You have painted regions in Neovim that you should edit.",
      "Edit ONLY the painted regions. Use the paint_edit tool with ALL edits in one call.\n",
    }
    for i, r in ipairs(regions) do
      local fname = r.file ~= "" and vim.fn.fnamemodify(r.file, ":~:.") or "[unnamed]"
      table.insert(ctx, string.format(
        "Region %d — %s lines %d–%d:\n```\n%s\n```",
        i - 1, fname, r.start_line, r.end_line,
        table.concat(r.lines, "\n")
      ))
    end
    table.insert(parts, { type = "text", text = table.concat(ctx, "\n") })
  end

  -- User message
  table.insert(parts, { type = "text", text = user_prompt })

  return parts
end

return M
