# lg-cc

Paint regions in Neovim, then let AI edit **only** those regions via [CodeCompanion.nvim](https://github.com/olimorris/codecompanion.nvim) + ACP.

## How it works

1. Visually select code → paint it as an editable region
2. Open CodeCompanion chat, reference `@{paint_edit}` in your prompt
3. The AI can **only** edit painted regions — enforced structurally via tool schema
4. You get an approval prompt before each edit is applied

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "your-user/lg-cc",
  dependencies = { "olimorris/codecompanion.nvim" },
  config = function()
    local lgcc = require("lg-cc")
    lgcc.setup()

    -- Paint keymaps (visual mode)
    vim.keymap.set("v", "<leader>pp", function()
      -- exit visual mode so '< '> marks are set
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
      vim.schedule(function() lgcc.paint() end)
    end, { desc = "Paint region" })

    vim.keymap.set("n", "<leader>pc", function() lgcc.clear() end, { desc = "Clear all paint" })
    vim.keymap.set("n", "<leader>pu", function() lgcc.clear_last() end, { desc = "Undo last paint" })
  end,
}
```

## CodeCompanion setup

Add the `paint_edit` tool to your CodeCompanion config:

```lua
require("codecompanion").setup({
  interactions = {
    chat = {
      adapter = "kiro_cli", -- or claude_code, opencode, etc.
      tools = {
        paint_edit = require("lg-cc").codecompanion_tool(),
      },
    },
  },
})
```

## Usage

1. Select lines in visual mode → `<leader>pp` to paint them
2. Paint more regions if needed (across files too)
3. `:CodeCompanionChat` to open chat
4. Type: `Use @{paint_edit} to implement error handling in the painted regions`
5. AI calls `paint_edit` for each region → you approve each edit

## Commands

| Command | Description |
|---|---|
| `:LgCCPaint` | Paint current visual selection |
| `:LgCCClear` | Clear all painted regions |
| `:LgCCClearLast` | Clear the last painted region |

## Why this approach?

The AI is **structurally constrained** — the tool schema only accepts a `region_id` and `new_code`. There's no way for it to edit outside painted areas. This is fundamentally different from prompt-based instructions like "only edit between lines X and Y" which the AI can ignore.
