--- CodeCompanion tool: paint_edit
--- Single call, all region edits at once. No AI ordering dependency.

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
    "You can ONLY edit painted regions.",
    "Call the tool ONCE with ALL edits in the `edits` array.\n",
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
          description = "Replace code in painted regions. Send ALL edits in one call.",
          parameters = {
            type = "object",
            properties = {
              edits = {
                type = "array",
                description = "Array of edits, one per region",
                items = {
                  type = "object",
                  properties = {
                    region_id = {
                      type = "integer",
                      description = "0-based index of the painted region",
                    },
                    new_code = {
                      type = "string",
                      description = "Complete replacement code for this region",
                    },
                  },
                  required = { "region_id", "new_code" },
                  additionalProperties = false,
                },
              },
            },
            required = { "edits" },
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
          local edits = args.edits or {}

          if #edits == 0 then
            return { status = "error", data = "No edits provided" }
          end

          -- Validate all region_ids before applying anything
          for _, e in ipairs(edits) do
            local idx = (e.region_id or -1) + 1
            if idx < 1 or idx > #regions then
              return {
                status = "error",
                data = string.format("Invalid region_id %s", tostring(e.region_id)),
              }
            end
          end

          diff.apply_all(regions, edits)
          paint.clear()

          return {
            status = "success",
            data = string.format("%d region(s) updated", #edits),
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
