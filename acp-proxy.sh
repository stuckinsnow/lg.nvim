#!/usr/bin/env bash
# ACP proxy — parses tool calls and forwards them to neovim
LOG_DIR="/tmp/acp-tap"
SOCK="/dev/shm/lg-tap.sock"
mkdir -p "$LOG_DIR"

REAL_AGENT="${REAL_KIRO_AGENT:-$(which kiro-cli)}"

# Use a named pipe so we can process stdout line by line
FIFO="$LOG_DIR/fifo.$$"
mkfifo "$FIFO"

# Start real agent with stdout going to our fifo
"$REAL_AGENT" "$@" > "$FIFO" &
AGENT_PID=$!

# Read from fifo, log everything, and forward to our stdout (back to TUI)
while IFS= read -r line; do
  echo "$line"  # forward to TUI
  echo "$line" >> "$LOG_DIR/stream.jsonl"
done < "$FIFO"

wait $AGENT_PID
rm -f "$FIFO"
