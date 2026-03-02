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

    for i, line in ipairs(buf_lines) do
      for col_start, word in line:gmatch("()([%a_][%w_]*)") do
        if not keywords[word] and not seen[word] then
          seen[word] = true
          local params = {
            textDocument = vim.lsp.util.make_text_document_params(bufnr),
            position = { line = start_line + i - 2, character = col_start - 1 },
          }
          local results = vim.lsp.buf_request_sync(bufnr, "textDocument/hover", params, 100)
          if results then
            for _, res in pairs(results) do
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
      end
    end

    if #hover_info > 0 then
      table.insert(parts, "Type Information:\n  " .. table.concat(hover_info, "\n  "))
    end
  end

  return table.concat(parts, "\n\n"), errors, warns, type_count
end

return M
