--- LSP context gathering for painted regions

local M = {}

local keywords = {
  ["function"] = true, ["return"] = true, ["if"] = true, ["else"] = true,
  ["for"] = true, ["while"] = true, ["do"] = true, ["end"] = true,
  ["local"] = true, ["then"] = true, ["in"] = true, ["repeat"] = true,
  ["until"] = true, ["break"] = true, ["goto"] = true, ["nil"] = true,
  ["true"] = true, ["false"] = true, ["not"] = true, ["and"] = true,
  ["or"] = true, ["const"] = true, ["let"] = true, ["var"] = true,
  ["import"] = true, ["export"] = true, ["default"] = true, ["from"] = true,
  ["class"] = true, ["extends"] = true, ["implements"] = true,
  ["interface"] = true, ["type"] = true, ["enum"] = true, ["new"] = true,
  ["this"] = true, ["super"] = true, ["typeof"] = true, ["instanceof"] = true,
  ["void"] = true, ["null"] = true, ["undefined"] = true, ["async"] = true,
  ["await"] = true, ["yield"] = true, ["throw"] = true, ["try"] = true,
  ["catch"] = true, ["finally"] = true, ["switch"] = true, ["case"] = true,
  ["continue"] = true, ["delete"] = true, ["with"] = true, ["as"] = true,
  ["of"] = true, ["static"] = true, ["public"] = true, ["private"] = true,
  ["protected"] = true, ["readonly"] = true, ["abstract"] = true,
  ["declare"] = true, ["module"] = true, ["require"] = true,
}

--- Diagnostics only (for @FILE_LSP)
--- @param bufnr number
--- @param start_line number 1-indexed
--- @param end_line number 1-indexed
--- @return string
function M.gather_diagnostics(bufnr, start_line, end_line)
  local lines = {}
  local errors, warns = 0, 0
  for _, d in ipairs(vim.diagnostic.get(bufnr)) do
    if d.lnum and d.lnum >= start_line - 1 and d.lnum < end_line then
      if d.severity == 1 then
        errors = errors + 1
        table.insert(lines, string.format("L%d: [ERROR] %s", d.lnum + 1, d.message or ""))
      elseif d.severity == 2 then
        warns = warns + 1
        table.insert(lines, string.format("L%d: [WARN] %s", d.lnum + 1, d.message or ""))
      end
    end
  end
  if #lines > 0 then return "Diagnostics:\n  " .. table.concat(lines, "\n  "), errors, warns end
  return "", 0, 0
end

--- Diagnostics + type info (for @LSP on painted regions)
--- Only includes symbols defined outside the painted region.
--- @param bufnr number
--- @param start_line number 1-indexed
--- @param end_line number 1-indexed
--- @return string
function M.gather(bufnr, start_line, end_line)
  local parts = {}

  local diag_text, errors, warns = M.gather_diagnostics(bufnr, start_line, end_line)
  if diag_text ~= "" then table.insert(parts, diag_text) end

  local type_count = 0
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients > 0 then
    local buf_lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
    local seen = {}
    local hover_info = {}
    local uri = vim.uri_from_bufnr(bufnr)

    for i, line in ipairs(buf_lines) do
      for col_start, word in line:gmatch("()([%a_][%w_]*)") do
        if #word > 1 and not keywords[word] and not seen[word] then
          seen[word] = true
          local pos = { line = start_line + i - 2, character = col_start - 1 }
          local params = {
            textDocument = vim.lsp.util.make_text_document_params(bufnr),
            position = pos,
          }

          -- Check if defined inside the painted region — skip if so
          local def_results = vim.lsp.buf_request_sync(bufnr, "textDocument/definition", params, 200)
          if def_results then
            local external = false
            for _, res in pairs(def_results) do
              local defs = res and res.result
              if defs then
                if defs.uri or defs.targetUri then defs = { defs } end
                for _, d in ipairs(defs) do
                  local def_uri = d.uri or d.targetUri
                  local def_range = d.range or d.targetSelectionRange
                  if def_uri and def_range then
                    local def_line = def_range.start.line -- 0-indexed
                    if def_uri ~= uri or def_line < (start_line - 1) or def_line >= end_line then
                      external = true
                      break
                    end
                  end
                end
              end
              if external then break end
            end
            if not external then goto continue end
          end

          do
            local hover_results = vim.lsp.buf_request_sync(bufnr, "textDocument/hover", params, 100)
            if hover_results then
              for _, res in pairs(hover_results) do
                local content = res and res.result and res.result.contents
                if type(content) == "table" and content.value then
                  local val = content.value:gsub("```%w*\n?", ""):gsub("\n", " "):gsub("%s+", " "):sub(1, 120)
                  if val ~= "" then
                    table.insert(hover_info, word .. ": " .. val)
                    type_count = type_count + 1
                  end
                end
              end
            end
          end
          ::continue::
        end
      end
    end

    if #hover_info > 0 then
      table.insert(parts, "Type Information:\n  " .. table.concat(hover_info, "\n  "))
    end
  end

  return table.concat(parts, "\n\n"), errors, warns, type_count
end

return M
