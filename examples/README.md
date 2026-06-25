# lg config examples

Drop-in agent and MCP configs for both providers. Replace `/path/to/lg` with
your plugin install path (e.g. `~/.local/share/nvim/lazy/lg`) and
`/path/to/devlens` with your devlens checkout in every file before using.

The `LG_INDEX_URL` env var (for the `@SEARCH` semantic search) is optional and
left out of these examples — add it to the `lg` server's env if you run an
embeddings server.

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

See the [Agents table](../README.md#agents) in the main README for what each
agent is allowed to do.
