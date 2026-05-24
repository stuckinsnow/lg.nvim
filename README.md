# lg

Paint regions in Neovim, then let an AI CLI edit **only** those regions via ACP.

Supports **kiro-cli** and **opencode** as providers.

## How it works

1. Visually select code → paint it as an editable region
2. Trigger send with a prompt
3. AI edits painted regions automatically — no approval prompts
4. Session persists between edits (clear when you want fresh context)

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "your-user/lg",
  build = "./build.sh",
  config = function()
    local lg = require("lg")
    lg.setup()

    -- Paint (visual mode)
    vim.keymap.set("v", "<leader>ap", function()
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
      vim.schedule(function() lg.paint() end)
    end, { desc = "Paint region" })

    -- Send painted regions to kiro-cli
    vim.keymap.set("n", "<leader>ae", function() lg.send() end, { desc = "Send to kiro-cli" })

    -- Management
    vim.keymap.set("n", "<leader>aP", function() lg.clear() end, { desc = "Clear all paint" })
    vim.keymap.set("n", "<leader>au", function() lg.clear_last() end, { desc = "Undo last paint" })
    vim.keymap.set("n", "<leader>am", function() lg.clear_marks() end, { desc = "Clear edit markers" })
    vim.keymap.set("n", "<leader>aX", function() lg.clear_session() end, { desc = "Clear session" })
    vim.keymap.set("n", "<leader>aW", function() lg.toggle_window() end, { desc = "Toggle panel" })

    -- Info paint
    vim.keymap.set("n", "<leader>aA", function() lg.accept_info_paint() end, { desc = "Convert info paint to real paint" })
    vim.keymap.set("n", "<leader>aI", function() lg.clear_info_paint() end, { desc = "Clear info paint" })

    -- Hints
    vim.keymap.set("n", "<leader>aH", function() lg.clear_hints() end, { desc = "Clear AI hints" })
  end,
}
```

## Building

A `build.sh` script builds all Go binaries:

```bash
./build.sh
```

This builds:
- `acp/lg-acp` — ACP session manager (subprocess bridge)
- `mcp/lg-mcp` — main MCP server
- `git-mcp/lg-git-mcp` — git MCP server
- `hint-mcp/lg-hint-mcp` — hint MCP server
- `lsp/lg-lsp` — hint LSP display server
- `tap/lg-tap` — ACP passthrough proxy for tap-chat mode

To run tests:

```bash
cd lsp && go test -v
cd mcp && go test -v
cd git-mcp && go test -v
```

## MCP Server Setup

lg uses MCP servers to expose tools to the AI CLI. The plugin starts a unix socket at `/dev/shm/lg.sock` on startup — you just need to tell your CLI where to find the MCP binaries.

### kiro-cli

Add to `~/.kiro/settings/mcp.json`:

```json
{
  "mcpServers": {
    "lg": {
      "command": "/path/to/lg/mcp/lg-mcp",
      "args": [],
      "env": { "LG_SOCK": "/dev/shm/lg.sock" }
    },
    "lg-git": {
      "command": "/path/to/lg/git-mcp/lg-git-mcp",
      "args": []
    }
  }
}
```

For the reviewer agent mode, add to `~/.kiro/agents/reviewer.json`:

```json
{
  "name": "reviewer",
  "mcpServers": {
    "lg-hint": {
      "command": "/path/to/lg/hint-mcp/lg-hint-mcp",
      "args": [],
      "env": { "LG_HINT_SOCK": "/dev/shm/lg-hint.sock" }
    }
  },
  "tools": ["read", "grep", "glob", "thinking", "@lg-hint"],
  "useLegacyMcpJson": false
}
```

### opencode

Add to `~/.config/opencode/opencode.json`:

```json
{
  "mcp": {
    "lg": {
      "type": "local",
      "command": ["/path/to/lg/mcp/lg-mcp"],
      "environment": { "LG_SOCK": "/dev/shm/lg.sock" },
      "enabled": true
    },
    "lg-git": {
      "type": "local",
      "command": ["/path/to/lg/git-mcp/lg-git-mcp"],
      "enabled": true
    }
  }
}
```

Replace `/path/to/lg` with the actual plugin install path (e.g. `~/.local/share/nvim/lazy/lg`).

## Usage

1. Select lines in visual mode → `<leader>ap` to paint them
2. Paint more regions if needed (across files too)
3. `<leader>ae` → type your prompt → edits applied automatically
4. Session persists — next edit has conversation context
5. `<leader>aX` to clear session and start fresh

## Prompt Prefixes

Use these prefixes in your prompt to enable special modes:

| Prefix | Description |
|---|---|
| `@INFO` | AI highlights regions that need changes and explains what to do — no code written. Use `<leader>aA` to convert highlighted regions to real paint. |
| `@HINT` | AI reviews code and publishes findings as editor diagnostics (squiggly underlines + hover messages). Read-only — no edits. Uses a dedicated reviewer agent mode. |
| `@SUGGEST` | AI publishes code suggestions as diagnostics — hover to see recommended code. |
| `@HELP` | AI highlights regions + publishes code suggestions for each. |
| `@GIT` | Spawns a cheap subagent (Haiku/GPT-4.1) to analyze git history, then injects the result as context into the main session. |
| `@SEARCH` | Tells the AI to use semantic codebase search (nomic-embed-text) before acting. Requires `LG_INDEX_URL`. |
| `@DIAG` | Tells the AI to check LSP diagnostics before making edits. |
| `@LSP` | Gathers LSP info (types, references) for painted regions and includes it as context. |
| `@FILE_LSP` | Gathers LSP diagnostics for the entire current file. |
| `@TSC` | Runs `tsc --noEmit` and includes type errors as context. |
| `@SUB` | Runs the next prefix as a subagent (e.g. `@SUB HINT`) — doesn't block the main session. |
| `@ASK` | Read-only chat — AI answers questions about painted code but cannot edit any files. |
| `@SHELL` | Spawns a shell subagent that runs commands with manual approval. |
| `@DEVLENS` | Inspects React components in the browser via DevLens, injects component state/props as context. |

Prefixes can be combined: `@DIAG @SEARCH fix the auth bug`

### Prompt Shortcuts

Use `#` shortcuts to quickly reference files in your prompt:

| Shortcut | Expands to |
|---|---|
| `#buffer` | `@<current file path>` |
| `#buffdir` | `@<current file's directory>/` |
| `#./` | `@` (relative path prefix) |

These are available as blink.cmp completions when typing `@` or `#` in the prompt.

## AI Hints (`@HINT`)

`@HINT` switches to a dedicated reviewer agent mode that can only annotate code, not edit it. The AI analyzes your code and publishes findings as native Neovim diagnostics:

- Squiggly underlines on the exact expression (uses string matching for precise column ranges)
- Hover messages with explanations
- Navigate findings with `[d` / `]d`
- Clear with `<leader>aH`

The hint system uses a separate LSP server (`lg-lsp`) that starts automatically. The AI calls the `lg_hint` MCP tool → hint MCP forwards to the LSP via unix socket → LSP publishes `textDocument/publishDiagnostics`.

Example: `@HINT find potential null pointer issues in this code`

## Chat Mode

Open the chat panel with `<leader>ac`. Messages sent from the chat window go through the same session but painted regions are hidden — the AI writes files directly instead of using `paint_edit`. A file watcher highlights git changes in real time without stealing focus from the chat.

## Tap Chat

Embeds the full Kiro TUI inside a Neovim terminal buffer. The `lg-tap` binary acts as an ACP passthrough proxy — it intercepts tool calls from the TUI and forwards them to Neovim over a unix socket. This gives you live diff previews in your editor as the TUI makes edits, with auto-accept on completion.

Toggle with `lg.tap_chat()`.

## Quick Edit

Visual select → prompt → edit in one step. Paints the selection, opens a prompt, and runs an isolated oneshot session that only touches that region. No need to manually paint first.

`<leader>aq` or `:LgQuickEdit`

## Quick Chat

Visual select → prompt → answer. Like quick edit but read-only — the AI answers questions about the selected code without making any edits.

`lg.quick_chat()`

## Context Paint

Paint regions as read-only context (not editable). These are sent alongside editable regions to give the AI more information without allowing it to modify them.

`<leader>ac` (visual) or `:LgContext`

## Smart Paint

Treesitter-aware painting — select a function/class/block by its AST node rather than line numbers.

`lg.smart_paint()`

## Paint from Commits

Paint regions that were modified in specific git commits. Pick commits via fzf, and the changed hunks become painted regions.

`lg.paint_from_commits()`

## Add File

Attach whole files as read-only context. Three methods available via `lg.add_file()`:
- Paste a file path
- Browse with mini.files
- Search with fzf

## Session Restore

List and reload previous sessions for the current project. Uses fzf with preview (rendered via glow).

`lg.restore_session()`

## Usage Dashboard

Shows Kiro credit usage in a floating window with progress bar, daily averages, and budget projections. Also sets the Kitty terminal progress bar via OSC 9;4.

`lg.usage()`

## Follow Reads

Highlights files in the editor as the AI reads them, so you can see what it's looking at in real time.

Toggle with `lg.toggle_follow()`.

## Clear Menu

An fzf-based menu to selectively clear different things (paint, context, markers, hints, session, follow highlights, or everything).

`lg.clear_menu()`

## Model & Provider Selection

Switch models or providers mid-session:

- `lg.select_model()` — pick from available models
- `lg.select_provider()` — switch between kiro and opencode

## Git Subagent

`@GIT` spawns a separate ACP session on a cheap model to analyze git history:

- **kiro**: uses `claude-haiku-4.5`
- **opencode**: uses `github-copilot/gpt-4.1`

The subagent has access to `git_log`, `git_show`, `git_diff`, and `git_blame` via its own MCP server. Its analysis is automatically injected into the main session as context — you don't need to copy anything.

Example: `@GIT something broke in the last 3 commits, find what changed in auth.ts`

## Commands

| Command | Description |
|---|---|
| `:LgPaint` | Paint current visual selection |
| `:LgClear` | Clear all painted regions |
| `:LgClearLast` | Clear the last painted region |
| `:LgSend [prompt]` | Send painted regions to kiro-cli |
| `:LgClearSession` | Kill session, start fresh |
| `:LgContext` | Paint visual selection as read-only context |
| `:LgClearContext` | Clear all context regions |
| `:LgClearAll` | Clear all paint + context |
| `:LgQuickEdit` | Quick edit: paint + prompt + isolated session in one step |
| `:LgToggle` | Toggle side panel |

## Config

```lua
lg.setup({
  session = {
    provider = "kiro",   -- "kiro" or "opencode"
  },
  window = {
    width = 50,
    position = "right",  -- "right" or "left"
  },
})
```
