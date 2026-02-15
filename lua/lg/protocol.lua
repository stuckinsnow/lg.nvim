--- Protocol: builds ACP prompt messages from painted regions

local M = {}

--- Build the prompt content array for session/prompt
--- @param regions table[] editable regions from paint.get_all()
--- @param context_regions table[] read-only regions from context.get_all()
--- @param user_prompt string
--- @return table[] ACP prompt content blocks
function M.build_prompt(regions, context_regions, user_prompt)
  local parts = {}

  -- Editable regions
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

  -- Read-only context
  if #context_regions > 0 then
    local ctx = { "### Context (read-only reference, do NOT edit these):\n" }
    for i, r in ipairs(context_regions) do
      local fname = r.file ~= "" and vim.fn.fnamemodify(r.file, ":~:.") or "[unnamed]"
      table.insert(ctx, string.format(
        "Context %d — %s lines %d–%d:\n```\n%s\n```",
        i - 1, fname, r.start_line, r.end_line,
        table.concat(r.lines, "\n")
      ))
    end
    table.insert(parts, { type = "text", text = table.concat(ctx, "\n") })
  end

  -- File context
  local files = require("lg.context").get_files()
  if #files > 0 then
    local ctx = { "### Files (read these for additional context):\n" }
    for _, f in ipairs(files) do
      table.insert(ctx, f)
    end
    table.insert(parts, { type = "text", text = table.concat(ctx, "\n") })
  end

  -- User message
  table.insert(parts, { type = "text", text = user_prompt })

  return parts
end

return M
