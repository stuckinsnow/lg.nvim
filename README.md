# lg-cc

Paint regions in Neovim, then let an AI CLI edit **only** those regions via ACP.

Supports **kiro-cli** and **opencode** as providers.

## How it works

1. Visually select code → paint it as an editable region
2. Trigger send with a prompt
3. AI edits painted regions automatically — no approval prompts
4. Session persists between edits (clear when you want fresh context)

## Architecture

```
lua/lg-cc/
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
  "your-user/lg-cc",
  build = "cd mcp && go build -o lg-cc-mcp .",
  config = function()
    local lgcc = require("lg-cc")
    lgcc.setup()

    -- Paint (visual mode)
    vim.keymap.set("v", "<leader>ap", function()
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
      vim.schedule(function() lgcc.paint() end)
    end, { desc = "Paint region" })

    -- Send painted regions to kiro-cli
    vim.keymap.set("n", "<leader>ae", function() lgcc.send() end, { desc = "Send to kiro-cli" })

    -- Management
    vim.keymap.set("n", "<leader>aP", function() lgcc.clear() end, { desc = "Clear all paint" })
    vim.keymap.set("n", "<leader>au", function() lgcc.clear_last() end, { desc = "Undo last paint" })
    vim.keymap.set("n", "<leader>am", function() lgcc.clear_marks() end, { desc = "Clear edit markers" })
    vim.keymap.set("n", "<leader>aX", function() lgcc.clear_session() end, { desc = "Clear session" })
    vim.keymap.set("n", "<leader>aW", function() lgcc.toggle_window() end, { desc = "Toggle panel" })
  end,
}
```

## MCP Server Setup

lg-cc uses an MCP server to expose `paint_edit` and `get_painted_regions` tools to the AI CLI. The plugin starts a unix socket at `/dev/shm/lg-cc.sock` on startup — you just need to tell your CLI where to find the MCP binary.

### kiro-cli

Add to `~/.kiro/settings/mcp.json`:

```json
{
  "mcpServers": {
    "lg-cc": {
      "command": "/path/to/lg-cc/mcp/lg-cc-mcp",
      "args": [],
      "env": { "LGCC_SOCK": "/dev/shm/lg-cc.sock" }
    }
  }
}
```

### opencode

Add to `~/.config/opencode/opencode.json`:

```json
{
  "mcp": {
    "lg-cc": {
      "type": "local",
      "command": ["/path/to/lg-cc/mcp/lg-cc-mcp"],
      "environment": { "LGCC_SOCK": "/dev/shm/lg-cc.sock" },
      "enabled": true
    }
  }
}
```

Replace `/path/to/lg-cc` with the actual plugin install path (e.g. `~/.local/share/nvim/lazy/lg-cc`).

## Usage

1. Select lines in visual mode → `<leader>ap` to paint them
2. Paint more regions if needed (across files too)
3. `<leader>ae` → type your prompt → edits applied automatically
4. Session persists — next edit has conversation context
5. `<leader>aX` to clear session and start fresh

## Commands

| Command | Description |
|---|---|
| `:LgCCPaint` | Paint current visual selection |
| `:LgCCClear` | Clear all painted regions |
| `:LgCCClearLast` | Clear the last painted region |
| `:LgCCSend [prompt]` | Send painted regions to kiro-cli |
| `:LgCCClearSession` | Kill session, start fresh |
| `:LgCCToggle` | Toggle side panel |

## Config

```lua
lgcc.setup({
  session = {
    provider = "kiro",   -- "kiro" or "opencode"
  },
  window = {
    width = 50,
    position = "right",  -- "right" or "left"
  },
})
```
