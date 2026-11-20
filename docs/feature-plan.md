# Feature Plan

- **Allow a selected line range to be context without becoming an edit scope**
  - A visual line range may be sent to the agent as focus/context.
  - It should not restrict the agent to editing only those lines.
  - The agent may still edit elsewhere in the buffer.
  - This feature exists somewhat as context paint but it does not bring up a chat prompt.

- **Improve and research the `@` menu/prefix system**
  - The current hint, suggest, help, context, chat, shell, and modifier prefixes are unclear in places.
  - Review and revise the naming and grouping of the `@` menu.
  - `@SUB` and the existing hint/suggest/help prefixes remain open for further thought.
