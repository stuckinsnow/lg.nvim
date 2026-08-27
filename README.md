# lg

https://github.com/user-attachments/assets/bf60cf75-cad0-404c-b550-132866b736fd

An AI coding client for Neovim, driven over ACP. Two ways to work:

- **Paint mode** — visually select regions and let the AI edit **only** those
  regions, nothing else in the file.
- **Chat mode** — a normal agentic chat panel with no region scoping. The AI
  reads, writes and creates files across the project, with edits landing as
  inline diffs in your buffers.

Both share one session, so you can scope an edit tightly, then open the chat and
keep the same conversation going.

Supports **kiro-cli** and **opencode** as providers.

## How it works

Paint mode:

1. Visually select code → paint it as an editable region
2. Trigger send with a prompt
3. AI edits painted regions automatically — no approval prompts
4. Session persists between edits (clear when you want fresh context)

Chat mode (`<leader>ac`): painted regions are ignored and the AI works on the
whole project like any other agentic CLI — see [Chat Mode](#chat-mode). `@ASK`
gives you the same thing read-only, and `fullstack` mode adds shell access.

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "stuckinsnow/lg",
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
cd acp && go test ./... -v
```

Lua tests run under headless Neovim:

```bash
nvim --headless -l tests/test_model_check.lua
nvim --headless -l tests/test_prompt_error.lua
```

## MCP Servers & Agents

lg drives the AI CLI by switching it between a set of **agents** — each agent is
locked to a specific role with a restricted tool set. Painting, chatting,
planning, reviewing, etc. each run under their own agent, so the model only ever
sees the tools that mode needs. The plugin switches agents per request via the
ACP `session/set_mode` call.

Setup has two parts:

1. **MCP servers** — expose lg's tools to the CLI (paint edits, file diffs, hints, git).
2. **Agents** — whitelist which of those tools each mode may use.

The plugin opens a unix socket at `/dev/shm/lg.sock` on startup; the MCP binaries
talk to Neovim over it. Hints use a second socket at `/dev/shm/lg-hint.sock`.

### MCP servers

| Server | Binary | Tools it exposes |
|---|---|---|
| `lg` | `mcp/lg-mcp` | `read_buffer`, `paint_edit`, `get_painted_regions`, `get_diagnostics`, `lg_write_file`, `lg_paint_regions`, `lg_search_codebase`, `handoff_to_chat` |
| `lg-git` | `git-mcp/lg-git-mcp` | `git_log`, `git_show`, `git_diff`, `git_blame` |
| `lg-hint` | `hint-mcp/lg-hint-mcp` | `lg_hint`, `lg_suggest`, `get_hints` |
| `devlens` | external devlens server (private, optional) | React component inspection |

### Agents

Each mode below maps to one agent. The tool column is the canonical whitelist —
configure the same set in whichever provider you use.

| Agent | Role | Whitelisted tools |
|---|---|---|
| `lg` | Paint edit (default) | `grep`, `glob`, `read_buffer`, `paint_edit`, `get_painted_regions`, `get_diagnostics`, `get_hints` |
| `lg-chat` | Chat edit via inline diff | `grep`, `glob`, `read_buffer`, `lg_write_file`, `get_diagnostics`, devlens |
| `lg-plan` | Planning, no writes | `grep`, `glob`, `read_buffer`, `handoff_to_chat` |
| `lg-oneshot` | Isolated quick edit | `grep`, `glob`, all `lg` tools, all `lg-git` tools |
| `lg-info` | Info paint (highlight only) | `read`, `grep`, `glob`, `lg_paint_regions` |
| `reviewer` | Hint diagnostics (read-only) | `read`, `grep`, `glob`, `lg_hint` |
| `suggester` | Code suggestions (read-only) | `read`, `grep`, `glob`, `lg_suggest` |
| `helper` | Highlight + suggest (read-only) | `read`, `grep`, `glob`, `lg_paint_regions`, `lg_hint`, `lg_suggest` |
| `asker` | Read-only Q&A | `read`, `grep`, `glob`, `get_hints` |
| `lg-shell` | Shell with manual approval | `read`, shell |
| `devlens` | React component inspection | `read`, `grep`, `glob`, devlens |
| `fullstack` | Full agentic mode | `read`, shell, `grep`, `glob`, all `lg` + `lg-git` tools, `get_hints` |

The two providers name and restrict tools differently:

- **kiro-cli** — one JSON file per agent in `~/.kiro/agents/`, with an explicit
  `tools` allow-list. MCP tools are referenced as `@server/tool` (e.g.
  `@lg/paint_edit`) or `@server` for every tool on a server (e.g. `@lg-hint`).
- **opencode** — a single `opencode.json` with an `agent` block. Tool access is
  controlled with `permission` rules rather than an allow-list, so each agent
  denies everything (`"*": "deny"`) and then allows what it needs. MCP tools are
  named `server_tool` (e.g. `lg_paint_edit`, `lg-hint_lg_hint`) and permission
  keys accept wildcards (`lg-hint_*`, `lg_*`).

### Setup

Ready-to-use configs live in [`examples/`](examples/) — copy them and replace
`/path/to/lg` (and `/path/to/devlens`) with your install paths. `LG_INDEX_URL`
(for `@SEARCH`) is optional; add it to the `lg` server's env if you run an
embeddings server.

**kiro-cli** — one JSON file per agent:

- `examples/kiro/settings/mcp.json` → `~/.kiro/settings/mcp.json`
- `examples/kiro/agents/*.json` → `~/.kiro/agents/`

Each agent declares the MCP server(s) it calls and lists its `tools`. MCP tools
are referenced as `@server/tool` (e.g. `@lg/paint_edit`) or `@server` for every
tool on a server (e.g. `@lg-hint`).

**opencode** — a single file:

- `examples/opencode/opencode.json` → `~/.config/opencode/opencode.json`

MCP servers are declared once under `mcp`; each agent is a `permission` whitelist
under `agent` that denies everything (`"*": "deny"`) then re-allows its tools (the
last matching rule wins). MCP tools are named `server_tool` and permission keys
accept wildcards (`lg-hint_*`, `lg_*`). Note the doubled prefix on
`lg_lg_write_file` / `lg_lg_paint_regions`: opencode prefixes MCP tools with the
server name, and these tools are themselves named `lg_write_file` /
`lg_paint_regions`.

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
