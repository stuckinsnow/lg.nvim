--- CodeCompanion tool definition for paint_edit
--- The LLM calls this tool to edit only painted regions

local paint = require("lg-cc.paint")

local M = {}

--- Build the system prompt dynamically with current painted regions
--- @return string
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

--- @return table CodeCompanion tool definition
function M.definition()
  return {
    description = "Edit painted code regions",
    opts = { require_approval_before = true },
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
        --- @param self table
        --- @param args table { region_id: number, new_code: string }
        --- @return { status: string, data: string }
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

          vim.schedule(function()
            vim.api.nvim_buf_set_lines(region.bufnr, region.start_line - 1, region.end_line, false, new_lines)
          end)

          local fname = region.file ~= "" and vim.fn.fnamemodify(region.file, ":~:.") or "[buffer]"
          return {
            status = "success",
            data = string.format("Region %d updated (%s:%d–%d, %d lines → %d lines)",
              args.region_id, fname, region.start_line, region.end_line,
              #region.lines, #new_lines),
          }
        end,
      },

      output = {
        --- @param self table
        --- @param tools table
        --- @return string
        prompt = function(self, tools)
          local regions = paint.get_all()
          local idx = (self.args.region_id or -1) + 1
          if idx < 1 or idx > #regions then
            return "Edit invalid region?"
          end
          local r = regions[idx]
          local fname = r.file ~= "" and vim.fn.fnamemodify(r.file, ":~:.") or "[buffer]"
          return string.format("Edit region %d (%s lines %d–%d)?", self.args.region_id, fname, r.start_line, r.end_line)
        end,

        --- @param self table
        --- @param tools table
        --- @param cmd table
        --- @param stdout table
        success = function(self, tools, cmd, stdout)
          tools.chat:add_tool_output(self, stdout[1])
        end,

        --- @param self table
        --- @param tools table
        --- @param cmd table
        --- @param stderr table
        error = function(self, tools, cmd, stderr)
          tools.chat:add_tool_output(self, "Error: " .. (stderr[1] or "unknown"))
        end,

        --- @param self table
        --- @param tools table
        rejected = function(self, tools, cmd)
          tools.chat:add_tool_output(self, "User rejected editing region " .. tostring(self.args.region_id))
        end,

        --- @param self table
        --- @param tools table
        cancelled = function(self, tools, cmd)
          tools.chat:add_tool_output(self, "User cancelled paint_edit")
        end,
      },
    },
  }
end

return M
