# Feature Plan

- **Add an in-place LSP/hint-style editing workflow**
  - Allow an agent to write code hints or explanations directly in the buffer.
  - This should be separate from the existing LSP context gathering behavior.
  - Research and revise the existing hint agent and naming instead of assuming a new `@ANNOTATE` name.

- **Allow a selected line range to be context without becoming an edit scope**
  - A visual line range may be sent to the agent as focus/context.
  - It should not restrict the agent to editing only those lines.
  - The agent may still edit elsewhere in the buffer.
  - This feature exists somewhat as context paint but it does not bring up a chat prompt.

- **Improve and research the `@` menu/prefix system**
  - The current hint, suggest, help, context, chat, shell, and modifier prefixes are unclear in places.
  - Review and revise the naming and grouping of the `@` menu.
  - `@SUB` and the existing hint/suggest/help prefixes remain open for further thought.

- **No implementation planned in this document**
  - This is a TODO/research list only.
  - Naming and behavior decisions remain to be made later.
