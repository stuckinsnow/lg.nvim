--- CodeCompanion tool definition for paint_edit
--- Edits are shown as inline diffs with accept/reject

local paint = require("lg-cc.paint")
local diff = require("lg-cc.diff")

local M = {}

local function build_system_prompt()
  local regions = paint.get_all()
  if #regions == 0 then
    return "## Paint Edit Tool\n\nNo regions are currently painted. Ask the user to paint regions first."
  end

  local parts = {
    "## Paint Edit Tool (`paint_edit`)\n",
    "You can ONLY edit painted regions. Do NOT attempt to edit anything outside these regions.",
    "Call the tool once per region you want to edit.\n",
    "### Available Regions:\n",
  }

  for i, r in ipairs(regions) do
    local fname = r.file ~= "" and vim.fn.fnamemodify(r.file, ":~:.") or "[unnamed buffer]"
    table.insert(parts, string.format(
      "**Region %d** — `%s` lines %d–%d:\n```\n%s\n```\n",
      i - 1, fname, r.start_line, r.end_line,
      table.concat(r.lines, "\n")
    ))
  end

  return table.concat(parts, "\n")
end

function M.definition()
  return {
    description = "Edit painted code regions",
    opts = { require_approval_before = false },
    callback = {
      name = "paint_edit",

      schema = {
        type = "function",
        ["function"] = {
          name = "paint_edit",
          description = "Replace code in a painted region. Only painted regions can be edited. Call once per region.",
          parameters = {
            type = "object",
            properties = {
              region_id = {
                type = "integer",
                description = "0-based index of the painted region to edit",
              },
              new_code = {
                type = "string",
                description = "The complete replacement code for this region",
              },
            },
            required = { "region_id", "new_code" },
            additionalProperties = false,
          },
          strict = true,
        },
      },

      system_prompt = function(_)
        return build_system_prompt()
      end,

      cmds = {
        function(self, args, _)
          local regions = paint.get_all()
          local idx = (args.region_id or -1) + 1

          if idx < 1 or idx > #regions then
            return {
              status = "error",
              data = string.format("Invalid region_id %s. Valid range: 0–%d", tostring(args.region_id), #regions - 1),
            }
          end

          local region = regions[idx]

          if not vim.api.nvim_buf_is_valid(region.bufnr) then
            return { status = "error", data = "Buffer is no longer valid" }
          end

          local new_lines = vim.split(args.new_code, "\n")
          diff.store(region.bufnr, region.start_line - 1, region.end_line, new_lines)

          local fname = region.file ~= "" and vim.fn.fnamemodify(region.file, ":~:.") or "[buffer]"
          return {
            status = "success",
            data = string.format("Region %d updated (%s:%d–%d) — use ga to accept, gr to reject",
              args.region_id, fname, region.start_line, region.end_line),
          }
        end,
      },

      output = {
        success = function(self, tools, cmd, stdout)
          tools.chat:add_tool_output(self, stdout[1])
        end,
        error = function(self, tools, cmd, stderr)
          tools.chat:add_tool_output(self, "Error: " .. (stderr[1] or "unknown"))
        end,
      },
    },
  }
end

return M
