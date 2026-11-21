# Prompt prefixes

You type a prefix such as `@REVIEW` at the start of a prompt to change what lg
does with it. Typing `@` in the prompt window lists them (blink.cmp
completion). This page describes each prefix by what you see in the editor.

Most prefixes work on **painted regions**: code you've selected with
`LgPaint` (editable) or `LgContext` (read-only reference). With no prefix,
the AI edits the painted regions directly.

## Quick reference

| Prefix      | Edits code?                 | Where the result shows up                                           | Needs paint? |
| ----------- | --------------------------- | ------------------------------------------------------------------- | ------------ |
| _(none)_    | Yes, painted regions only   | The buffer                                                          | Yes          |
| `@ASK`      | No                          | Chat panel                                                          | No           |
| `@INFO`     | No                          | Highlighted regions, quickfix list, chat panel                      | No           |
| `@REVIEW`   | No                          | Diagnostics in the buffer and quickfix list                         | No           |
| `@ANNOTATE` | Yes                         | The buffer, plus annotation diagnostics and the quickfix list       | No           |
| `@SUGGEST`  | No                          | Diagnostics with hover preview, `gra` apply action, quickfix list   | No           |
| `@HELP`     | No                          | Highlighted regions, suggestions, and quickfix list                 | No           |
| `@SHELL`    | No                          | Chat panel (runs shell commands you approve)                        | No           |
| `@GIT`      | Yes, after the git analysis | Chat panel, then the buffer                                         | No           |
| `@DEVLENS`  | Yes                         | The buffer                                                          | No           |
| `#lsp`      | Yes                         | The buffer                                                          | Yes          |
| `#file_lsp` | Yes                         | The buffer                                                          | Yes          |
| `@DIAG`     | Yes                         | The buffer                                                          | Yes          |
| `@TSC`      | Yes                         | The buffer                                                          | Yes          |
| `@SUB`      | Modifier                    | Runs `@REVIEW`, `@SUGGEST` or `@HELP` in the background             | No           |

## Asking and reviewing (no edits)

### `@ASK`

Read-only chat. The AI answers questions about your code in the chat panel
and can't edit any files. Painted regions are sent along as context.

Example: `@ASK why does this retry loop never exit?`

### `@INFO`

Points at code without changing it. The AI highlights the regions it wants to
talk about and explains them in the chat panel. Each highlighted region is
also added to the **quickfix list** as `AI - <reason>`, so `:copen` and
`:cnext` walk through them.

Your recent chat history is included, so a follow-up like
`@INFO where else does this happen?` works.

What you can do with the highlights:

- `lg.accept_info_paint()` turns them into normal paint, ready for an edit.
- `lg.copy_info_paint()` copies them to the clipboard as `path:line-range`.
- `lg.clear_info_paint()`, or "Info paint" in the clear menu, removes them.

Runs as a separate session, so it doesn't block the main one.

### `@REVIEW`

Code review. The AI publishes its findings as **diagnostics** (the same
markers your LSP uses), so they show up inline, in `vim.diagnostic` lists,
and in the **quickfix list** (`:copen`). Use the "Dismiss"
code action (`gra`) to drop one, or "AI hints" in the clear menu to drop all
of them.

If the AI finishes without publishing anything, lg retries once.

### `@ANNOTATE`

A normal edit that also explains itself. The AI makes the edits you ask for,
then calls `lg_annotate` (part of `lg-mcp`, so it works on every provider;
blocked on normal turns unless `@ANNOTATE` is used) to publish an annotation
for each change as a diagnostic: what changed and why, with more detail on
hover.

With painted regions it runs as a paint edit. Without paint (or from the chat
panel) it runs in chat mode. If you only ask it to annotate ("annotate my
uncommitted changes"), it skips editing and only annotates.

When it finishes, the new annotations go into the **quickfix list**
(title `lg annotations`), so `:copen` / `:cnext` walk through them. If the AI
forgets to annotate, lg asks it once more (without redoing the edits).

Example: `@ANNOTATE comment out the debug logging`

### `@SUGGEST`

Like `@REVIEW`, but each diagnostic carries concrete replacement code. Hover
(`K`) over a diagnostic to preview the suggested code, or trigger code actions
(`gra`) and choose **Apply** to replace the lines and dismiss the suggestion.
New suggestions are also added to the **quickfix list** (`:copen`).

### `@HELP`

`@INFO` and `@SUGGEST` combined. The AI highlights the regions that need
changes and publishes a suggestion diagnostic for each one (added to the
**quickfix list**, with hover preview and `gra` apply action).

### `@SUB`

Put it in front of `@REVIEW`, `@SUGGEST` or `@HELP` (`@SUB @REVIEW ...`) to run
that review in a separate background session, so the main session stays free.
Without `@SUB`, lg asks whether to queue or use a background session when the
main session is busy.

## Running things for you

### `@SHELL`

A separate session that can run shell commands. Each command asks for your
approval first. Output and the AI's reply appear in the chat panel.

### `@GIT`

A cheap model (claude-haiku-4.5 on Kiro, github-copilot/auto on opencode) first looks
through git history to answer your question. Its findings appear in the chat
panel, then your request is sent to the main session with them as context.

Example: `@GIT when did this function start returning nil?`

### `@DEVLENS`

Asks for DevLens tokens, fetches the live state of those React/Preact
components from your browser, and sends it to the AI with your request.
Needs a running DevLens server.

## Adding context to an edit

These add information to a normal paint edit. You can combine them, for
example `@DIAG #lsp fix the auth bug`.

- `#lsp`: types and diagnostics from your language server for each painted
  region.
- `#file_lsp`: diagnostics for the whole current file instead.

- `@DIAG`: tells the AI to check diagnostics in your open buffers before
  editing.
- `@TSC`: runs `tsc --noEmit` and includes the type errors. The output also
  appears in the chat panel.

## When prefixes are combined

Only one of these runs per prompt. lg checks them in this order and uses the
first one it finds: `@DEVLENS`, `@SHELL`, `@GIT`, `@ASK`, `@REVIEW`, `@ANNOTATE`, `@SUGGEST`,
`@HELP`, `@INFO`. The context prefixes (`#lsp`, `#file_lsp`, `@DIAG`, `@TSC`)
apply to the normal edit that runs when none of those are present.
