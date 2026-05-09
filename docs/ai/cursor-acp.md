# Cursor ACP

Cursor has **native ACP support** via the `cursor-agent acp` subcommand. No adapter needed.

## Launch

```bash
cursor-agent acp
```

Also available as `agent acp` (`agent` is a symlink to `cursor-agent`).

Speaks standard ACP over stdin/stdout as JSON-RPC lines.

## Capabilities (from `initialize` response)

```json
{
  "protocolVersion": 1,
  "agentCapabilities": {
    "loadSession": true,
    "mcpCapabilities": { "http": true, "sse": true },
    "promptCapabilities": {
      "audio": false,
      "embeddedContext": false,
      "image": true
    },
    "sessionCapabilities": { "list": {} }
  },
  "authMethods": [
    {
      "id": "cursor_login",
      "name": "Cursor Login",
      "description": "Authenticate using existing Cursor login credentials. Run 'agent login' first if not logged in."
    }
  ]
}
```

Compared to kiro:

- ✅ `loadSession: true`
- ✅ `mcpCapabilities: { http: true, sse: true }` (kiro only has `http: true`)
- ✅ `sessionCapabilities.list` — can list past sessions
- ❌ No `stdio` MCP transport advertised (kiro doesn't either, but lg's MCP servers use unix sockets via env var so this is fine)
- ❌ Requires auth: must run `cursor-agent login` first

## Modes (what kiro calls "agents")

Cursor sends these in `session/new` response under `modes.availableModes`:

| id      | name  | description                                                     |
| ------- | ----- | --------------------------------------------------------------- |
| `agent` | Agent | Full agent capabilities with tool access                        |
| `plan`  | Plan  | Read-only mode for planning and designing before implementation |
| `ask`   | Ask   | Q&A mode — no edits or command execution                        |

Only 3 modes. No equivalent to kiro's `lg`, `lg-chat`, `lg-oneshot`, `reviewer`, `suggester`, `helper`, `fullstack`, etc.

**Mode mapping for lg integration** (similar to the existing `opencode_modes` table):

```lua
local cursor_modes = {
  lg           = "agent",
  ["lg-chat"]  = "agent",
  ["lg-plan"]  = "plan",
  ["lg-oneshot"] = "agent",
  ["lg-info"]  = "agent",
  reviewer     = "plan",
  suggester    = "plan",
  helper       = "plan",
  asker        = "ask",
  fullstack    = "agent",
  kiro_default = "agent",
  kiro_planner = "plan",
}
```

## Models

26 models available. Model IDs include bracketed parameters (thinking/context/reasoning/effort/fast).
Examples:

- `default[]` — Auto (default)
- `composer-2[fast=true]`
- `claude-opus-4-7[thinking=true,context=300k,effort=xhigh]`
- `claude-sonnet-4-6[thinking=true,context=200k,effort=medium]`
- `claude-haiku-4-5[thinking=true]`
- `gpt-5.5[context=272k,reasoning=medium,fast=false]`
- `gpt-5.3-codex[reasoning=medium,fast=false]`
- `gemini-3.1-pro[]`
- `grok-4.3[context=200k]`
- `kimi-k2.5[]`

**Credit multipliers:** ❌ Not surfaced in the ACP `availableModels` or `configOptions`. Only `modelId` and `name`. If Cursor publishes pricing, it's not through ACP.

**Cheap model candidate for subagents:** `claude-haiku-4-5[thinking=true]` or `gpt-5.4-mini[reasoning=medium]` or `gemini-2.5-flash[]`.

## Slash commands

Cursor sends commands via `session/update` with `sessionUpdate: "available_commands_update"` — **different from kiro's** `_kiro.dev/commands/available` notification.

```json
{
  "method": "session/update",
  "params": {
    "sessionId": "...",
    "update": {
      "sessionUpdate": "available_commands_update",
      "availableCommands": [
        { "name": "copy-request-id", "description": "..." },
        { "name": "simplify", "description": "..." },
        { "name": "worktree", "description": "..." },
        { "name": "best-of-n", "description": "..." },
        ...
      ]
    }
  }
}
```

Commands are skills/builtins, not system commands. No equivalent to kiro's `/usage`, `/compact`, `/model`, `/chat save`, `/context`, `/mcp`, etc. **Everything lg currently uses slash commands for (usage tracking, compaction) is kiro-specific.**

Built-in commands seen:

- `copy-request-id`, `simplify`, `worktree`, `best-of-n`, `babysit`, `create-hook`, `create-rule`, `create-skill`, `create-subagent`, `migrate-to-skills`, `sdk`, `shell`, `split-to-prs`, `statusline`, `update-cli-config`

## `_kiro.dev/*` notifications

❌ Not applicable. These are kiro-proprietary. Cursor uses pure standard ACP only.

That means for Cursor:

- No `_kiro.dev/metadata` → no automatic context % or metering usage
- No `_kiro.dev/commands/execute` passthrough
- No `_kiro.dev/compaction/status`

## Known issues

From the Cursor forum:

1. **MCP regression fixed** — as of April 2026, `mcpServers` passed in `session/new` now works again (was broken earlier).
2. **`session/load`** — returns "Invalid params" despite `loadSession: true` being advertised. Might be fixed now but unverified.
3. **Auth required** — must run `cursor-agent login` before using ACP mode. If not logged in, session/new might fail.
4. **Str replace / file edits in read-only modes** — The agent is not supposed to edit files, but you can still use string-replace style edit tools (e.g. `lg_write_file` with `old_text`/`new_text`, or equivalent) and they apply. Mode restrictions are not fully enforced for those code paths today.

## Integration plan for lg.nvim

### Minimal (to make it work)

1. Add `cursor` entry in both `providers` tables (`acp/main.go` + `lua/lg/session/session.lua`):

   ```go
   "cursor": {"cursor-agent", "acp"},
   ```

   ```lua
   cursor = { cmd = { "cursor-agent", "acp" }, name = "Cursor" },
   ```

2. Add `cursor_modes` mapping in `session.lua` alongside `opencode_modes` and extend `resolve_mode()`:

   ```lua
   if opts.provider == "cursor" then
     return cursor_modes[mode_id] or "agent"
   end
   ```

3. Update subagent cheap-model map for `@GIT` etc.:
   ```lua
   local cheap = {
     kiro = "claude-haiku-4.5",
     opencode = "github-copilot/gpt-4.1",
     cursor = "claude-haiku-4-5[thinking=true]",
   }
   ```

### Things that won't work on Cursor (document as known limitations)

- `<leader>a8S` usage panel — depends on `/usage` command
- `:LgCompact` / `M.compact()` — depends on `_kiro.dev/commands/execute` with `command: "compact"`
- Metering display — depends on `_kiro.dev/metadata` notifications
- Context % display — same
- Credit multipliers in model picker — not in Cursor ACP responses

### Things that should "just work"

- Paint + send (core flow)
- MCP tools (`paint_edit`, `get_painted_regions`) — advertised as supported
- Mode switching (agent/plan/ask)
- Model switching (via `session/set_model`)
- Session loading (probably — needs verification)
- Slash command picker (if we add it back, but with cursor's different notification type)

### Small concerns

- Auth: the plugin should probably check for `cursor-agent` login status before starting the session (or at least surface a clear error when session/new fails).
- Model list is 26 entries, picker will be long. Might want sorting / filtering by model family (GPT, Claude, Gemini, etc.).
