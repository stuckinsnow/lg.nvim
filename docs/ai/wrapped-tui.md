# ACP Protocol & Wrapped TUI

## Overview

The kiro TUI (`tui.js`) communicates with the agent (`kiro-cli`) over **ACP** — a JSON-RPC 2.0 protocol over stdin/stdout. By setting `KIRO_CHAT_CLI_BIN`, you can inject a proxy between the TUI and the real agent.

## Wrapped TUI (lg-tap)

Embeds the kiro TUI inside a neovim terminal buffer while tapping ACP events to drive editor features (diff preview, accept/reject).

### Architecture

```
neovim terminal buffer
    │
    ├── jobstart() with term=true
    │       │
    │       ▼
    │   bun tui.js chat --tui
    │       │
    │       │  KIRO_CHAT_CLI_BIN=lg-tap
    │       ▼
    │   lg-tap (Go binary, stdin/stdout proxy)
    │       │
    │       ├── stdin:  scanner → agent.stdin  (+ logs to /tmp/acp-tap/stdin.jsonl)
    │       ├── stdout: tap(agent.stdout, os.Stdout)  ← passthrough + event extraction
    │       │
    │       └── unix socket /dev/shm/lg-tap.sock ──► neovim (lua listener)
    │
    └── tap-chat.lua: opens terminal, listens on socket, drives hunk UI
```

### How to launch

```bash
KIRO_CHAT_CLI_BIN=/path/to/lg-tap \
REAL_KIRO_AGENT=kiro-cli \
    ~/.local/share/kiro-cli/bun \
    ~/.local/share/kiro-cli/tui.js chat --tui
```

The TUI thinks it's talking to `kiro-cli` but actually talks to `lg-tap`, which forwards everything to the real agent and taps stdout.

### What lg-tap taps

It parses JSON lines from agent stdout and forwards these to neovim via the socket:

| Event | Forwarded when |
|-------|---------------|
| `session/update` (tool_call, tool_call_update) | Edit diffs for preview |
| `session/request_permission` | Permission prompts |
| `fs/write_text_file`, `fs/read_text_file` | File operations |
| Result with `stopReason` | Turn ended |

### Neovim side (tap-chat.lua)

- Opens a vsplit with a terminal buffer running the wrapped TUI
- Listens on `/dev/shm/lg-tap.sock` for tap events
- On `tool_call` with `kind: "edit"`: shows diff preview via `hunk.propose_edit()`
- On `tool_call_update` with `status: "completed"`: auto-accepts all hunks
- On turn end (`stopReason`): rejects any remaining previews

### Sending commands to the wrapped TUI

**Keystroke simulation** (current):
```lua
require("lg.tap-chat")._send("/usage\r")
```

**JSON-RPC injection** (possible, not yet implemented):
The socket is currently one-way (agent → neovim). To inject messages, make it bidirectional — accept JSON on the socket → write to agent stdin.

### Log files

- `/tmp/acp-tap/tap.jsonl` — all agent stdout (responses + events)
- `/tmp/acp-tap/stdin.jsonl` — all TUI stdin (requests sent to agent)

## ACP Protocol Details

All messages are newline-delimited JSON-RPC 2.0:

```json
{"jsonrpc":"2.0","method":"...","params":{...},"id":1}
```

- **Requests** have an `id` — expect a response with the same `id`
- **Notifications** have no `id` — fire-and-forget
- **Responses** have `result` or `error` + matching `id`

### Client → Agent methods (stdin)

| Method | Params | Description |
|--------|--------|-------------|
| `initialize` | `{protocolVersion, clientCapabilities, clientInfo}` | Handshake |
| `session/new` | `{cwd, mcpServers}` | Create new session |
| `session/prompt` | `{sessionId, prompt}` | Send a user message |
| `session/set_mode` | `{sessionId, modeId}` | Switch agent mode |
| `session/set_model` | `{sessionId, modelId}` | Switch model |
| `session/cancel` | `{sessionId}` | Cancel current turn (notification, no id) |
| `session/list` | `{cwd}` | List available sessions |
| `session/load` | `{sessionId, cwd, mcpServers}` | Resume a session |
| `_kiro.dev/commands/execute` | `{sessionId, command: {command, args}}` | Run a slash command |

### Agent → Client events (stdout)

| Method | Description |
|--------|-------------|
| `_kiro.dev/metadata` | Context/metering usage after each turn |
| `_kiro.dev/commands/available` | Available commands, tools, MCP servers |
| `_kiro.dev/mcp/server_initialized` | MCP server ready |
| `_kiro.dev/subagent/list_update` | Subagent status |
| `session/update` | Tool calls, streaming content |
| `session/request_permission` | Permission prompts (fs write, etc.) |

### Command format

The TUI sends commands as an object, not a string:

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "_kiro.dev/commands/execute",
  "params": {
    "sessionId": "...",
    "command": {"command": "usage", "args": {}}
  }
}
```

### /usage response

```json
{
  "success": true,
  "message": "Plan: KIRO POWER | 1 usage breakdowns",
  "data": {
    "planName": "KIRO POWER",
    "billingCycleReset": "2026-06-01",
    "overagesEnabled": false,
    "isEnterprise": true,
    "usageBreakdowns": [{
      "resourceType": "CREDIT",
      "displayName": "Credits",
      "used": 1206.73,
      "limit": 10000.0,
      "percentage": 12,
      "currentOverages": 0.0,
      "overageRate": 0.04,
      "overageCharges": 0.0,
      "currency": "USD"
    }],
    "bonusCredits": []
  }
}
```

### Metadata push (after each turn)

```json
{
  "jsonrpc": "2.0",
  "method": "_kiro.dev/metadata",
  "params": {
    "sessionId": "...",
    "contextUsagePercentage": 1.39,
    "meteringUsage": [
      {"value": 0.043, "unit": "credit", "unitPlural": "credits"}
    ],
    "turnDurationMs": 2433
  }
}
```

### Getting the Session ID

Comes back in the `session/new` response:

```json
{"jsonrpc":"2.0","result":{"sessionId":"2283e85e-..."},"id":2}
```

Or from any `_kiro.dev/metadata` / `_kiro.dev/commands/available` notification (includes `sessionId` in params).

## Building an ACP-only client

To bypass the TUI entirely:

1. Spawn `kiro-cli acp`
2. Send `initialize` → get capabilities
3. Send `session/new` → get `sessionId`
4. Send `session/prompt` with your message
5. Read streaming `session/update` events from stdout
6. Send `_kiro.dev/commands/execute` for slash commands
