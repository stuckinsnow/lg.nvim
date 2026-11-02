# Adding Claude as an lg provider

Build notes for adding Claude Code as a third lg backend, next to kiro-cli and
opencode. They were written before Claude was installed on this machine, so
nothing here has been run against a live adapter. Everything below comes from
reading lg's code and the adapter's source.

- **Adapter:** [`@agentclientprotocol/claude-agent-acp`](https://github.com/agentclientprotocol/claude-agent-acp)
  v0.100.0, commit `1e986b5` (2026-11-02). Its binary is `claude-agent-acp`
  (`dist/index.js`).
- **lg baseline:** `main` at `64ceee8`.

Facts are tagged:

- **[verified-src]**: read in the adapter's or lg's source.
- **[docs]**: from Claude Code docs (https://code.claude.com/docs/en/sub-agents).
- **[unverified]**: an assumption. Test it before relying on it (see "Smoke tests").

Scope for the first pass: **paint edit (`lg` agent) and chat (`lg-chat`)**,
plus switching between them. Model selection is optional; the default model is
fine.

---

## 1. Summary

Claude Code doesn't speak ACP itself. `claude-agent-acp` wraps the Claude Agent
SDK and speaks ACP over stdio, so it fits lg's existing `lg-acp` Go bridge in
the same place as `kiro-cli acp` and `opencode acp`.

Per-mode tool restriction works through Claude Code **custom agents**, one
markdown file per agent in `~/.claude/agents/`. The adapter switches agents
**live** with `session/set_config_option` (`configId: "agent"`), not
`session/set_mode`. That one difference drives most of the work.

> **Main risk [unverified]:** the plan assumes that a live agent switch also
> changes which tools Claude can call (the new agent's `tools` list). The
> adapter source only confirms that the switch "takes effect on the next
> turn". It doesn't say whether that covers tools or only the prompt. If the
> tool list doesn't change, the paint and chat modes leak tools into each
> other, and lg must use the fallback instead: one session per mode, which
> loses the chat history when switching. **Run smoke test T2 (section 6.3)
> before writing any of the switching code.**

| Concern           | kiro                                                     | opencode                      | claude (via claude-agent-acp)                                                        |
| ----------------- | -------------------------------------------------------- | ----------------------------- | ------------------------------------------------------------------------------------ |
| Spawn             | `kiro-cli acp`                                           | `opencode acp`                | `claude-agent-acp`                                                                   |
| Agent definitions | `~/.kiro/agents/*.json`                                  | `opencode.json` `agent` block | `~/.claude/agents/*.md` (YAML frontmatter + prompt body)                             |
| Tool restriction  | `tools` allow-list                                       | `permission` deny/allow       | frontmatter `tools` allow-list (+ `disallowedTools`)                                 |
| MCP tool naming   | `@lg/paint_edit`                                         | `lg_paint_edit`               | `mcp__lg__paint_edit`                                                                |
| Switch agent      | `session/set_mode` or `_kiro.dev/commands/execute agent` | `session/set_mode`            | `session/set_config_option {configId:"agent", value}`                                |
| ACP "modes" mean  | lg agents                                                | lg agents                     | **permission modes** (default/acceptEdits/plan/…), not agents                        |
| Models            | `models.availableModels`                                 | `configOptions[id=model]`     | `configOptions[id=model]` (already parsed by `ParseModelsInfo`)                      |
| Set model         | `session/set_model`                                      | `session/set_model`           | `session/set_config_option {configId:"model"}`; no `session/set_model` handler found |
| Session list      | reads `~/.kiro/sessions/cli/*.json`                      | sqlite `opencode.db`          | ACP `session/list` (adapter implements it)                                           |
| Session load      | `session/load`                                           | `session/load`                | `session/load` (`loadSession: true`)                                                 |
| Vendor extensions | `_kiro.dev/*`                                            | none                          | `_meta.claudeCode.*`, `_claude/*`                                                    |

---

## 2. Facts about claude-agent-acp

### 2.1 Live agent switching [verified-src]

`src/acp-agent.ts`:

- The adapter discovers custom agents at session start with
  `q.supportedAgents()`. It filters out built-ins (`claude`,
  `general-purpose`, `Explore`, `Plan`, `statusline-setup`) and the reserved
  id `"default"` (`src/session-config-ids.ts`: `DEFAULT_AGENT_ID = "default"`).
- If at least one custom agent exists, it adds a session config option with
  `id: "agent"`. **If none exist, the option is omitted entirely.** The agent
  files must exist before lg creates the session.
- `setSessionConfigOption` with `configId === "agent"`:

  ```ts
  // Live agent switch — no subprocess restart needed. ...
  // the change takes effect on the next turn (SDK >= 0.3.161).
  await session.query.applyFlagSettings({
    agent: value === DEFAULT_AGENT_ID ? null : value,
  });
  ```

  The conversation is kept, so the flow resembles what lg does today on kiro:
  switch to `lg-chat`, prompt, switch back to `lg`. **It only fully matches
  kiro if the switch also changes the tool list, which is unverified** (see
  the main risk in section 1 and smoke test T2).

- The value is the agent's `name` (the frontmatter `name`, normally equal to
  the filename).

### 2.2 Session creation options [verified-src]

`session/new` accepts `_meta.claudeCode.options`, which is passed to the SDK
`Options`. The adapter manages `cwd`, `permissionMode`, `canUseTool` and
`executable` itself. It merges `hooks`, `mcpServers` and `disallowedTools`.
`tools`, `allowedTools`, `agent`, `agents` and `systemPrompt` are passed
through.

lg doesn't need this for the first pass, because agent files on disk plus live
switching are enough. If live switching turns out not to re-scope tools
(smoke test T2), the fallback is `_meta.claudeCode.options.agent = "<name>"`
on a fresh `session/new` for each mode.

### 2.3 Permission requests [verified-src]

- Option kinds are the standard ACP ones: `allow_once`, `allow_always`,
  `reject_once`. lg's `findOption(...)` already works with these.
- Each tool call has a `kind`, and the `title` depends on the tool
  (`src/tool-calls/reporters/*.ts`):

  | Tool                               | `kind`    | `title`                                                    |
  | ---------------------------------- | --------- | ---------------------------------------------------------- |
  | Bash                               | `execute` | **the raw command string**, e.g. `git push`, or `Terminal` |
  | Edit/Write/MultiEdit               | `edit`    | file-oriented                                              |
  | Read                               | `read`    | file-oriented                                              |
  | Grep/Glob                          | `search`  | label                                                      |
  | WebFetch/WebSearch                 | `fetch`   |                                                            |
  | Task/Agent, TodoWrite              | `think`   |                                                            |
  | **MCP tools** and anything unknown | `other`   | the tool name, e.g. `mcp__lg__paint_edit`                  |

- **This breaks lg's approval heuristic.** `acp/internal/session/session.go`
  `handlePermission` asks for approval only when the title starts with
  `Creating `, `Deleting ` or `Running` (kiro wording) or contains `devlens`.
  Claude's Bash titles are just the command, so **Bash would be
  auto-approved**. Claude needs a kind-based rule (see 4.4).
- `protocol.PermissionTool` only decodes `title`. Add `kind`, and optionally
  `rawInput` and `locations`, to the struct.

### 2.4 Model handling [verified-src]

- Models come back in `configOptions` (`id: "model"`). lg's
  `protocol.ParseModelsInfo` already falls back to this for opencode, so the
  model list should parse unchanged.
- No `session/set_model` handler showed up in the adapter. Model changes go
  through `session/set_config_option {configId:"model", value}`. lg's Go
  `SetModel` ignores the response, so an unsupported call is harmless, but the
  model won't change. It's low priority: either skip `set_model` for Claude or
  route it through the new `set_config_option` (4.2).
- `models.lua` `pick_model` first calls `_kiro.dev/commands/options` and falls
  back to the live models table when that fails. That should work as is.

### 2.5 Sessions [verified-src]

- The adapter advertises `loadSession: true` and implements `listSessions`.
- lg's Lua `restore.lua` `list_sessions_acp` already understands the standard
  ACP shape (`data.sessions[]` with `sessionId`, `title`, `updatedAt`).
- `Manager.ListSessions(cwd)` (a `session/list` passthrough) already exists in
  `acp/internal/session/manager.go`, but `conn.go` doesn't call it. It calls
  `history.go listSessions(provider, cwd)` instead.
- Claude stores transcripts at `~/.claude/projects/<cwd-with-slashes-as-dashes>/<sessionId>.jsonl`
  [unverified exact encoding]. There is no ACP delete, so delete by removing
  that file.

### 2.6 Auth [verified-src, from t3code + adapter]

lg doesn't handle auth. The adapter uses whatever Claude Code is logged in
with: subscription OAuth from `claude auth login`, `ANTHROPIC_API_KEY`, or
Bedrock/Vertex. The adapter also advertises ACP auth methods (terminal login),
which lg can ignore. If it isn't logged in, prompts fail with an auth error,
which lg's existing `prompt_error` path will show.

### 2.7 Agent file format [docs]

`~/.claude/agents/<name>.md` (user) or `.claude/agents/<name>.md` (project,
higher priority):

```markdown
---
name: lg-chat
description: Chat mode — edits files via inline diff review
tools: Read, Grep, Glob, mcp__lg__read_buffer, mcp__lg__lg_write_file, mcp__lg__get_diagnostics
---

<system prompt body>
```

Supported frontmatter: `description`, `tools`, `disallowedTools`, `model`,
`permissionMode`, `mcpServers`, `hooks`, `maxTurns`, `skills`, `initialPrompt`,
`memory`, `effort`, `background`, `omitClaudeMd`, `isolation`.

- Field names are camelCase. **Unknown fields are silently ignored**, so a typo
  quietly drops a restriction.
- `tools` is an allow-list. If no entry resolves to a real tool, the agent
  usually fails to launch.
- `model` accepts `sonnet`, `opus`, `haiku`, a full id, or `inherit`.
- `mcpServers` entries are either the name of an already configured server or
  an inline definition.

---

## 3. Design decisions

### D1. Agent switching: config option, not mode

> **Before building this:** this design depends on the unverified main risk in
> section 1. Run smoke test T2 first. If T2 fails, skip the live-switch helper
> below and build the session-per-mode fallback (see "Alternatives
> considered").

Add a Go and Lua `set_config_option(session_id, config_id, value)` call. For
`provider == "claude"`, every place lg calls `set_mode(sid, resolve_mode(x))`
should call `set_config_option(sid, "agent", resolve_mode(x))` instead.

Do this **in one place**: add a Lua helper `switch_agent(sid, mode_id, cb)`
that chooses the transport by provider, and replace the raw `client.set_mode`
calls with it. The call sites on `64ceee8`:

| File                          | Line       | Context                                                           |
| ----------------------------- | ---------- | ----------------------------------------------------------------- |
| `lua/lg/session/session.lua`  | ~245       | after `create_session`, set `lg`                                  |
| `lua/lg/session/session.lua`  | ~619, ~630 | `send_chat`: to `lg-chat`/`lg-plan`, then back                    |
| `lua/lg/session/session.lua`  | ~660, ~676 | `send_mode`: temporary mode, then back to `lg`                    |
| `lua/lg/session/session.lua`  | ~802       | after `compact`                                                   |
| `lua/lg/session/session.lua`  | ~943–957   | `set_planner`: kiro uses `execute_command agent`, else `set_mode` |
| `lua/lg/session/session.lua`  | ~917       | `_run_handoff`: `execute_command agent lg-chat` (kiro-only today) |
| `lua/lg/session/subagent.lua` | ~149       | subagent `set_mode_then_prompt`                                   |
| `lua/lg/session/restore.lua`  | ~166       | after `session_loaded`, set `lg`                                  |

Line numbers are approximate. Search for `set_mode(` and `execute_command(.*"agent"`.

**Ordering matters.** The switch "takes effect on the next turn". lg sends
`set_mode` and then `prompt` without waiting, which works on kiro because both
go over the same pipe in order. With Claude, **wait for the
`set_config_option` response before sending the prompt**. Otherwise the prompt
could start while `applyFlagSettings` is still pending. `send_chat` and
`send_mode` currently don't wait, so the helper should take a callback and
those call sites should prompt from inside it.

Alternatives considered:

- **A new session per mode** (`_meta.claudeCode.options.agent`). This loses
  the chat history between paint and chat. Keep it as the fallback if T2
  fails.
- **One agent with all tools, enforced by lg rejecting permissions.** That
  doesn't work, because Read/Grep/Glob never ask for permission, and the model
  would see tools it shouldn't use.
- **Putting the mode in the prompt.** Rejected as hackish.

### D2. MCP servers: register globally, restrict per agent

Two options:

- **(a) Recommended for the first pass.** Register `lg`, `lg-hint`, `lg-git`
  (and `devlens`) once in Claude Code's user config with
  `claude mcp add-json -s user ...`. Each agent's `tools` list then narrows
  what that agent can use. This is the same model as opencode (global `mcp`,
  per-agent permissions). It doesn't depend on whether the main-thread agent's
  `mcpServers` frontmatter is honored on a live switch.
- **(b)** Inline `mcpServers` in each agent's frontmatter, like kiro's
  per-agent `mcpServers`. [unverified] whether a main-session agent (not a
  subagent) picks these up, and whether a live switch starts or stops servers.
  Test it with T3 before switching to it.

lg's `opts.mcp_servers` → `create_session` path sends a **map**. ACP specifies
an **array** of `{name, command, args, env:[{name,value}]}`. Leave it empty for
Claude. Don't route lg's MCP servers through `session/new` unless the format is
fixed to the ACP array.

### D3. Approval rules for Claude

Add a `Provider` (or a `needsApproval func`) to `Session`, set from `Manager`
when the session is created, and use a Claude rule in `handlePermission`:

- `kind == "execute"` → manual approval (Bash).
- `kind == "edit"` or `"delete"` or `"move"` → manual approval. lg's agents
  shouldn't have Edit/Write at all, so if this fires, the agent files are
  wrong. Approve it manually rather than silently.
- `kind == "other"` and the title starts with `mcp__lg__`, `mcp__lg-hint__` or
  `mcp__lg-git__` → auto-approve. These are lg's own tools, and lg already
  shows diffs for writes.
- `kind == "other"` and the title contains `devlens` → manual (current behavior).
- `read`, `search`, `think` → auto-approve after the existing path guard.

Keep the kiro path exactly as it is. Don't change kiro behavior as a side
effect.

**Path guard.** The guard pulls paths from kiro title wording (`Reading /x`).
Claude titles differ, and Claude's Read/Grep/Glob inside the project usually
**don't ask for permission at all**, so the guard never sees them. lg's
sensitive-file blocklist (`.env`, keys, …) is therefore **not enforced** for
Claude reads. Mitigations, in order of preference:

1. Use `locations[].path` from the permission `toolCall` (ACP standard field)
   when it's present, instead of parsing the title.
2. Add deny rules to Claude settings (`~/.claude/settings.json`):
   `"permissions": {"deny": ["Read(./.env)", "Read(./.env.*)", "Read(**/*.pem)", "Read(**/*.key)"]}`.
   Ship this as `examples/claude/settings.json`.
3. The lg agents use `mcp__lg__read_buffer` for reads, but `Read`/`Grep`/`Glob`
   are still listed, so (2) matters.

`fs/read_text_file` requests (lg advertises `fs.readTextFile: true` in
`InitializeRequest`) still go through `handleFSRead` and the guard, if the
adapter uses the client fs [unverified]. Log them during T1 to find out.

---

## 4. Implementation plan

Work on branch `claude`. Each step is small enough to review on its own.

### 4.1 Register the provider

- `acp/main.go` `providers`: add `"claude": {"claude-agent-acp"}`. Update the
  flag help text (`kiro, opencode or claude`).
- `lua/lg/session/session.lua` `providers`: add
  `claude = { cmd = { "claude-agent-acp" }, name = "Claude" }`.
  `models.select_provider` picks it up automatically.
- `lua/lg/health.lua`: if it checks provider executables, add `claude-agent-acp`
  (and `claude` for login). It only checked `go` when this was written, so
  this is optional.

### 4.2 Go: `set_config_option`

- `protocol/protocol.go`:

  ```go
  func SessionSetConfigOptionRequest(id int, sessionID, configID, value string) Message {
      params, _ := json.Marshal(map[string]any{"sessionId": sessionID, "configId": configID, "value": value})
      return Message{JSONRPC: "2.0", ID: NewID(id), Method: "session/set_config_option", Params: params}
  }
  ```

  [unverified] The exact param names follow the ACP schema (`sessionId`,
  `configId`, `value`). Check them against `@agentclientprotocol/sdk`
  `SetSessionConfigOptionRequest` in the adapter's `node_modules` before
  shipping.

- `session/session.go`: add a `SetConfigOption(configID, value string, onDone func(*protocol.Message)) error`
  that **tracks the response** and returns it to the caller. Unlike `SetMode`,
  the caller needs to know when it's done (D1 ordering) and whether it failed.
- `server/conn.go`: add a `case "set_config_option":` that reads
  `req.ConfigID` and `req.Value` (add both to `Request` in `server.go`) and
  replies `{ok}` or `{error}` **after** the ACP response arrives (the same
  pattern as `execute_command`).
- Emit an event when the response carries `configOptions`. Claude also pushes
  `session/update` with `sessionUpdate: "config_option_update"`, which already
  goes out as a generic `update` event. Optionally map it to an
  `agent_switched` event with `{agentName, previousAgentName}` so the existing
  Lua `agent_switched` handler (planner state, status line) works unchanged.

### 4.3 Lua: one agent-switch helper

- `client.lua`: `M.set_config_option(session_id, config_id, value, callback)`.
- `modes.lua`: add a `claude` branch. The lg mode ids **are** the agent names,
  so the mapping is the identity, except `kiro_default` → `lg-chat` and
  `kiro_planner` → `lg-plan`. Reuse the `opencode_modes` table as a shared
  table rather than copying it.
- Add `M.switch_agent(provider, sid, mode_id, cb)` (in `modes.lua` or
  `session.lua`):
  - `claude` → `client.set_config_option(sid, "agent", resolve(mode_id), cb)`
  - otherwise → `client.set_mode(sid, resolve(mode_id), cb)`
- Replace every call site in the D1 table. In `send_chat` and `send_mode`,
  send the prompt from inside the callback.
- `set_planner` and `_run_handoff`: add a `claude` branch that uses the helper
  instead of `execute_command(..., "agent", ...)`. `_run_handoff` must prompt
  inside the callback.
- `subagent.lua` `set_mode_then_prompt`: use the helper. It already waits for
  the callback.
- `restore.lua` after `session_loaded`: use the helper. Agent discovery
  happens per session, so check T5.

### 4.4 Go: Claude permission rules

- `protocol/types.go` `PermissionTool`: add `Kind string \`json:"kind"\``,
`RawInput json.RawMessage \`json:"rawInput,omitempty"\``,
`Locations []struct{ Path string \`json:"path"\` } \`json:"locations,omitempty"\``.
- Pass the provider into the session. `Manager` already has the cmd. Add a
  `provider string` to `NewManager(cmd, clientName, provider)` and to the
  `Session` built in `CreateSession` and `LoadSession`.
- `session.go handlePermission`: at the top,
  `if s.provider == "claude" { s.handleClaudePermission(msg, params); return }`.
  Write `handleClaudePermission` from the D3 rules, reusing the existing
  "send to Lua for approval" and "auto-approve" code. Pull those two
  blocks into small helpers (`askUser(msg, params, dir)` and
  `autoApprove(msg, params)`), because they're duplicated three or four times
  already. Do this only if it stays a mechanical extraction that leaves kiro
  behavior unchanged.

### 4.5 History

- `server/history.go`: give `listSessions` access to the manager (or move the
  call into `conn.go`). For `claude`, return `mgr.ListSessions(cwd)` as is.
  Lua already parses that shape.
- `deleteSession` for `claude`: glob
  `~/.claude/projects/*/<sessionId>.jsonl` and remove the match. Validate that
  `sessionID` matches `^[A-Za-z0-9-]+$` first, so a crafted id can't escape
  the glob. The opencode branch also builds SQL from the id with `Sprintf`.
  That's a separate issue and out of scope here.

### 4.6 Model check, info, subagent defaults

- `model-check.lua` `pinned_models`: Claude agents can pin `model:` in their
  frontmatter. Leave it kiro-only for now (`provider ~= "kiro"` → `{}`).
  Claude's `model` values are aliases like `sonnet` that won't match
  configOption ids, so validating them would give false warnings.
- `session.lua M.info()`: it lists `~/.kiro/agents/*.json`. For Claude, list
  `~/.claude/agents/*.md` and parse the `name`/`tools` lines from the
  frontmatter. This is cosmetic and can be skipped.
- `subagent.lua` `cheap` tables: add `claude = "haiku"` [unverified: the
  configOption value is probably a full id, not the alias]. Because set_model
  is a no-op for Claude until 4.2 routes it, this only matters later. Skipping
  `set_model` when `provider == "claude"` is fine for the first pass.
- `send_quick_chat` hardcodes opencode. Leave it.

### 4.7 Examples and docs

- `examples/claude/agents/*.md`: one per lg agent. Port **`lg` and `lg-chat`
  first**, then the rest from `examples/kiro/agents/*.json`, using the
  README's canonical tool table.
- `examples/claude/mcp.sh` (or a README snippet): the `claude mcp add-json -s user`
  commands for `lg`, `lg-hint`, `lg-git` (D2a).
- `examples/claude/settings.json`: the read deny rules (D3).
- `examples/README.md`: add a `## claude` section.
- `README.md`: "Supports kiro-cli, opencode and Claude Code", the provider
  config comment (`"kiro", "opencode" or "claude"`), and a Claude bullet under
  "The two providers name and restrict tools differently" (make that "three").
- Install note, per the repo's pnpm rule:
  `pnpm add -g @agentclientprotocol/claude-agent-acp`, plus Claude Code itself
  and `claude auth login`.

---

## 5. Example agent files (first pass)

Tool names follow `mcp__<server>__<tool>`. [unverified] Claude keeps hyphens
in server names (`mcp__lg-hint__get_hints`). If it doesn't, rename the server
to `lg_hint` when registering it. Check with T1.

`~/.claude/agents/lg.md`

```markdown
---
name: lg
description: Neovim lg paint mode — edits only painted regions via paint_edit
tools: Grep, Glob, mcp__lg__read_buffer, mcp__lg__paint_edit, mcp__lg__get_painted_regions, mcp__lg__get_diagnostics, mcp__lg-hint__get_hints
---

When the user rejects an edit (permission denied), acknowledge it and move on.
Do not retry the rejected edit using a different tool or approach.
Do not use npm or npx.
```

`~/.claude/agents/lg-chat.md`

```markdown
---
name: lg-chat
description: Chat mode — edits files via inline diff review, no painted regions
tools: Grep, Glob, mcp__lg__read_buffer, mcp__lg__lg_write_file, mcp__lg__get_diagnostics
---

Use the lg_write_file tool to edit files. Read the file first, then use
old_text/new_text to replace only the changed portion. Include enough
surrounding context in old_text for a unique match. The user sees an inline
diff and can accept or reject. If rejected, acknowledge and move on.
```

Notes:

- Neither file lists `Edit`, `Write`, `MultiEdit`, `NotebookEdit` or `Bash`.
  That's what makes the restriction hold without relying on the prompt.
- `Read` is left out of `lg` and `lg-chat` to match the kiro agents
  (`read_buffer` only). The read-only agents (`reviewer`, `asker`, …) list
  `Read`, matching kiro's `read`.
- Kiro's `thinking` tool has no equivalent and isn't needed.
- `fullstack` and `lg-shell` get `Bash`. lg-shell's manual approval comes from
  D3 (`kind == "execute"`).
- When an agent runs as the main session agent, a non-empty body probably
  replaces Claude Code's default system prompt. The docs only say that an
  empty prompt leaves the system prompt unchanged, so this is inferred
  [docs, inferred]. Keep each body self-contained.

Register the MCP servers (D2a). Replace `/path/to/lg`:

```sh
claude mcp add-json -s user lg '{"command":"/path/to/lg/mcp/lg-mcp","env":{"LG_SOCK":"/dev/shm/lg.sock"}}'
claude mcp add-json -s user lg-hint '{"command":"/path/to/lg/hint-mcp/lg-hint-mcp","env":{"LG_HINT_SOCK":"/dev/shm/lg-hint.sock","LG_SOCK":"/dev/shm/lg.sock"}}'
claude mcp add-json -s user lg-git '{"command":"/path/to/lg/git-mcp/lg-git-mcp"}'
```

---

## 6. Tests

### 6.1 Unit tests (write them, they don't need Claude installed)

Go, in the style of `acp/internal/protocol/types_test.go`:

- `protocol`: `SessionSetConfigOptionRequest` marshals to
  `{"method":"session/set_config_option","params":{"sessionId":…,"configId":"agent","value":"lg-chat"}}`.
- `protocol`: `ParseModelsInfo` on a Claude-shaped `session/new` result
  (`configOptions` containing both `{id:"agent",…}` and `{id:"model",…}`)
  returns only the model list and isn't confused by the agent option.
- `protocol`: `PermissionParams` decodes `toolCall.kind`, `rawInput` and
  `locations`.
- `session`: a table-driven test of the Claude approval rule. Factor it into a
  pure `claudeNeedsApproval(kind, title string) bool` so the test doesn't need
  a process. Cases: `execute`/`git push` → true, `other`/`mcp__lg__paint_edit`
  → false, `other`/`mcp__devlens__x` → true, `edit`/anything → true,
  `read` → false.
- `server`: `deleteSession("claude", "../../etc")` is rejected by the id
  validation.

Lua, if there's a harness (see `test_*.lua` at the repo root):

- `modes.resolve_mode("claude", "kiro_planner") == "lg-plan"`,
  `("claude", "lg") == "lg"`.
- `switch_agent` sends `set_config_option` for claude and `set_mode` otherwise.
  Stub `client`.

### 6.2 Fake adapter (optional, no Claude needed)

A tiny Go program under `acp/internal/testdata/fakeclaude/` that speaks
just enough ACP over stdio would let `go test` drive the real bridge:

- `initialize` → `{protocolVersion:1}`
- `session/new` → `{sessionId, configOptions:[agent, model]}`
- `session/set_config_option` → records the value and returns the updated
  `configOptions`
- `session/prompt` → sends one `session/request_permission` with a given
  `kind`/`title`, then `{stopReason:"end_turn"}`

An end-to-end test would then check that the switch is acknowledged before the
prompt is sent, and that `execute` permissions surface as `permission_request`
rather than being auto-approved. This is worth it if the ordering logic in D1
gets complicated.

### 6.3 Smoke tests (once Claude is installed)

Run them in order. Each one decides whether a design choice holds.

- **T0 install and login.** `claude auth login`, then
  `pnpm add -g @agentclientprotocol/claude-agent-acp`, then check that
  `which claude-agent-acp` finds it.
- **T1 discovery and naming.** Put `lg.md` and `lg-chat.md` in
  `~/.claude/agents/` and register the MCP servers. Start lg with
  `provider = "claude"` and look in `/dev/shm/lg-acp.log` for the
  `session/new` result. Check that `configOptions` includes `id:"agent"` with
  `lg` and `lg-chat`, and note the exact MCP tool names (hyphen question).
- **T2 live switch re-scopes tools (the key one).** In `lg`, ask "list every
  tool you can call". Switch to `lg-chat` with `set_config_option`, then ask
  again. The lists should differ (`paint_edit` ↔ `lg_write_file`). **If they
  don't, use the D1 fallback** (session per mode with
  `_meta.claudeCode.options.agent`).
- **T3 MCP availability across switches.** After a switch, call an lg tool.
  It should still work. Also try D2b (inline `mcpServers`) if you want
  per-agent servers.
- **T4 approvals.** In `fullstack`, ask it to run `ls`. You should get a
  manual approval prompt, not `permission_auto` in the log.
- **T5 restore.** Run `session/list` and `session/load`, then switch to `lg`.
  The agent option should exist on loaded sessions too.
- **T6 sensitive reads.** Ask the `asker` agent to read `.env`. With the
  settings deny rules it should be refused. Without them, note that it
  succeeds (see D3).

---

## 7. Open questions

- Exact `session/set_config_option` param names, and whether a value not in
  the option list is rejected or silently ignored.
- Whether `applyFlagSettings({agent})` also applies the agent's `tools`,
  `mcpServers` and `permissionMode` mid-session, or only its prompt (T2/T3).
- Whether Claude normalizes hyphens in MCP server names in tool ids (T1).
- Whether the adapter uses ACP client `fs/read_text_file` for Read (affects
  the guard) (T1 log).
- Whether the `config_option_update` notification arrives before or after
  the `set_config_option` response. It only matters for status-line updates.
