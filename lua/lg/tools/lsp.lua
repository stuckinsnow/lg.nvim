--- LSP context gathering for painted regions

local M = {}

--- Gather LSP info for a buffer region
--- @param bufnr number
--- @param start_line number 1-indexed
--- @param end_line number 1-indexed
--- @return string
function M.gather(bufnr, start_line, end_line)
  local lines = {}
  
  -- Diagnostics
  local diags = vim.diagnostic.get(bufnr, { lnum = start_line - 1 })
  local region_diags = {}
  for _, d in ipairs(diags) do
    if d.lnum and d.lnum >= start_line - 1 and d.lnum < end_line then
      local severity = (d.severity == 1) and "ERROR" or "WARN"
      local message = d.message or ""
      table.insert(region_diags, string.format("L%d: [%s] %s", d.lnum + 1, severity, message))
    end
  end
  
  if #region_diags > 0 then
    table.insert(lines, "Diagnostics:")
    for _, diag_line in ipairs(region_diags) do
      table.insert(lines, "  " .. diag_line)
    end
  end
  
  -- Hover info for symbols in range
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients > 0 then
    local buf_lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
    local symbols = {}
    
    for i, line in ipairs(buf_lines) do
      for word in line:gmatch("[%w_]+") do
        if not symbols[word] then
          symbols[word] = start_line + i - 1
        end
      end
    end
    
    local hover_info = {}
    for word, lnum in pairs(symbols) do
      local params = {
        textDocument = vim.lsp.util.make_text_document_params(bufnr),
        position = { line = lnum - 1, character = 0 }
      }
      
      local results = vim.lsp.buf_request_sync(bufnr, "textDocument/hover", params, 100)
      if results then
        for _, res in pairs(results) do
          if res and res.result and res.result.contents then
            local content = res.result.contents
            if type(content) == "table" and content.value then
              local value = tostring(content.value):gsub("\n", " "):sub(1, 100)
              table.insert(hover_info, word .. ": " .. value)
            end
          end
        end
      end
    end
    
    if #hover_info > 0 then
      table.insert(lines, "\nType Information:")
      for _, info in ipairs(hover_info) do
        table.insert(lines, "  " .. info)
      end
    end
  end
  
  return table.concat(lines, "\n")
end

return M
