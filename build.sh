#!/bin/bash
# Build lg's unified Go binary (acp, lsp, mcp subcommands).
#
# The binary is gitignored, so this has to run after a fresh clone —
# lazy.nvim does it via `build = "./build.sh"`, or run :LgBuild inside nvim.
#
# The binary is written to ./lg (for tools that reference it by repo path,
# e.g. kiro agent configs) and installed into the shared directory the plugin
# resolves at runtime, keeping lua/lg/bin.lua in sync:
#
#   $LG_BIN_DIR, else ${XDG_DATA_HOME:-~/.local/share}/nvim/lg/bin

set -euo pipefail

cd "$(dirname "$0")"

if ! command -v go >/dev/null 2>&1; then
	echo "lg: Go is required to build the binary — https://go.dev/dl" >&2
	exit 1
fi

BIN_DIR="${LG_BIN_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lg/bin}"
mkdir -p "$BIN_DIR"

echo "Building lg..."
go build -o lg ./cmd/lg
rm -f "$BIN_DIR/lg-acp" "$BIN_DIR/lg-lsp" "$BIN_DIR/lg-mcp" "$BIN_DIR/lg-hint-mcp" "$BIN_DIR/lg-git-mcp"
install -m 755 lg "$BIN_DIR/lg"

echo "Done — lg installed in $BIN_DIR"
