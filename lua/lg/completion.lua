--- @module 'blink.cmp'

--- @class blink.cmp.Source
local M = {}

local at_items = {
  { label = "@LSP", detail = "Gather type info and diagnostics from LSP for painted regions" },
  { label = "@GIT", detail = "Spawn a cheap model to analyze git history, inject as context" },
  { label = "@SEARCH", detail = "Semantic codebase search with nomic-embed-text before acting" },
  { label = "@DIAG", detail = "Check LSP diagnostics in open buffers before editing" },
  { label = "@INFO", detail = "AI highlights regions and explains changes — no code written" },
  { label = "@TSC", detail = "Run tsc --noEmit and include type errors as context" },
  { label = "@HINT", detail = "AI reviews code and publishes findings as editor diagnostics" },
  { label = "@SUGGEST", detail = "AI publishes code suggestions as diagnostics — hover to see recommended code" },
  { label = "@SUB", detail = "Run next prefix as a subagent (e.g. @SUB HINT) — doesn't block main session" },
}

local hash_items = {
  { label = "#buffer", detail = "Insert current file path as @file reference" },
  { label = "#buffdir", detail = "Insert current file's directory as @dir/ reference" },
  { label = "#./", detail = "Shorthand — expands to @ (relative path prefix)" },
}

function M.new()
  return setmetatable({}, { __index = M })
end

function M:get_trigger_characters()
  return { "@", "#" }
end

function M:enabled()
  return vim.bo.filetype == "lgprompt" or vim.bo.filetype == "markdown"
end

function M:get_completions(ctx, callback)
  local trigger = ctx.trigger.character or ctx.line:sub(ctx.bounds.start_col - 1, ctx.bounds.start_col - 1)
  local line = ctx.line
  local edit_range = {
    start = { line = ctx.bounds.line_number - 1, character = ctx.bounds.start_col - 2 },
    ["end"] = { line = ctx.bounds.line_number - 1, character = ctx.bounds.start_col + ctx.bounds.length },
  }

  local source, prefix
  if trigger == "@" then
    source, prefix = at_items, "@"
  elseif trigger == "#" then
    source, prefix = hash_items, "#"
  else
    return callback()
  end

  local result = {}
  for _, item in ipairs(source) do
    if not line:find(item.label, 1, true) then
      table.insert(result, {
        kind = vim.lsp.protocol.CompletionItemKind.Keyword,
        label = item.label:sub(#prefix + 1),
        insertText = item.label .. " ",
        textEdit = { newText = item.label .. " ", range = edit_range },
        documentation = { kind = "markdown", value = item.detail },
      })
    end
  end

  callback({ context = ctx, is_incomplete_forward = false, is_incomplete_backward = false, items = result })
end

return M
