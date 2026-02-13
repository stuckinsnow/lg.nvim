# lg-cc

Paint regions in Neovim, then let kiro-cli edit **only** those regions via ACP.

## How it works

1. Visually select code → paint it as an editable region
2. Trigger send with a prompt
3. kiro-cli edits painted regions automatically — no approval prompts
4. Session persists between edits (clear when you want fresh context)

## Architecture

```
lua/lg-cc/
├── init.lua      -- Entry point, thin orchestrator
├── paint.lua     -- Visual region painting with extmarks
├── diff.lua      -- Buffer editing + gutter markers
├── session.lua   -- kiro-cli ACP subprocess lifecycle
├── protocol.lua  -- ACP/JSON-RPC message building
└── window.lua    -- Optional side panel (regions + history)
```

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "your-user/lg-cc",
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
    cmd = "kiro-cli",    -- CLI command
    args = { "acp" },    -- ACP mode
  },
  window = {
    width = 50,
    position = "right",  -- "right" or "left"
  },
})
```
