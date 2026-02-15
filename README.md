# lg

Paint regions in Neovim, then let an AI CLI edit **only** those regions via ACP.

Supports **kiro-cli** and **opencode** as providers.

## How it works

1. Visually select code → paint it as an editable region
2. Trigger send with a prompt
3. AI edits painted regions automatically — no approval prompts
4. Session persists between edits (clear when you want fresh context)

## Architecture

```
lua/lg/
├── init.lua      -- Entry point, thin orchestrator
├── paint.lua     -- Visual region painting with extmarks
├── diff.lua      -- Buffer editing + gutter markers
├── session.lua   -- ACP subprocess lifecycle
├── protocol.lua  -- ACP/JSON-RPC message building
├── server.lua    -- Unix socket server for MCP bridge
└── window.lua    -- Optional side panel (regions + history)

mcp/
└── main.go       -- MCP server (paint_edit + get_painted_regions tools)
```

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "your-user/lg",
  build = "cd mcp && go build -o lg-mcp .",
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
  end,
}
```

## MCP Server Setup

lg uses an MCP server to expose `paint_edit`, `get_painted_regions`, `lg_search_codebase`, and `get_diagnostics` tools to the AI CLI. The plugin starts a unix socket at `/dev/shm/lg.sock` on startup — you just need to tell your CLI where to find the MCP binary.

### kiro-cli

Add to `~/.kiro/settings/mcp.json`:

```json
{
  "mcpServers": {
    "lg": {
      "command": "/path/to/lg/mcp/lg-mcp",
      "args": [],
      "env": { "LG_SOCK": "/dev/shm/lg.sock" }
    }
  }
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

## Commands

| Command | Description |
|---|---|
| `:LgPaint` | Paint current visual selection |
| `:LgClear` | Clear all painted regions |
| `:LgClearLast` | Clear the last painted region |
| `:LgSend [prompt]` | Send painted regions to kiro-cli |
| `:LgClearSession` | Kill session, start fresh |
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
