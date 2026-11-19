# lg config examples

Drop-in agent and MCP configs for both providers. Replace `/path/to/lg` with
your plugin install path (e.g. `~/.local/share/nvim/lazy/lg`) and
`/path/to/devlens` with your devlens checkout in every file before using.

The `devlens` MCP server and agent are optional (devlens is a separate, private
tool). If you don't use it, drop the `devlens` MCP entry and the `devlens` /
`lg-chat` devlens references.

## kiro-cli

```
~/.kiro/
├── settings/mcp.json        ← examples/kiro/settings/mcp.json
└── agents/
    ├── lg.json              ← examples/kiro/agents/*.json (one file per agent)
    ├── lg-chat.json
    └── ...
```

Copy `examples/kiro/settings/mcp.json` to `~/.kiro/settings/mcp.json` and every
file in `examples/kiro/agents/` to `~/.kiro/agents/`.

## opencode

```
~/.config/opencode/opencode.json   ← examples/opencode/opencode.json
```

Copy `examples/opencode/opencode.json` to `~/.config/opencode/opencode.json`
(or merge its `mcp` and `agent` blocks into your existing config).

## antigravity (agy)

```
~/.gemini/config/hooks.json        ← examples/antigravity/hooks.json
```

Antigravity needs no agent or MCP config files — `lg.nvim` attaches `lg-mcp`
automatically in `session/new` and maps modes onto Antigravity's `default` /
`plan` modes. Log in with `agy` once beforehand.

Copy `examples/antigravity/hooks.json` to `~/.gemini/config/hooks.json` (or
merge the `lg-deny-direct-edits` entry into your existing `hooks.json`) so
Antigravity blocks `read_file`, `write_file`, `edit_file`, and `run_command`
when `LG_ACP=1` is set by `lg-acp`, forcing reads/edits through `read_buffer` /
`paint_edit` / `lg_write_file` while leaving normal `agy` CLI sessions
unaffected.

See the [Agents table](../README.md#agents) in the main README for what each
agent is allowed to do.
