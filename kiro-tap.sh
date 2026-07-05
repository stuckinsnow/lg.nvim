#!/bin/bash
# Launch kiro TUI with ACP tap enabled
export REAL_KIRO_AGENT="$(which kiro-cli)"
export KIRO_CHAT_CLI_BIN="$(dirname "$0")/acp-proxy.sh"
~/.local/share/kiro-cli/bun ~/.local/share/kiro-cli/tui.js chat --tui
