#!/bin/bash
# Build lg's Go binaries.
#
# The binaries are gitignored, so this has to run after a fresh clone —
# lazy.nvim does it via `build = "./build.sh"`, or run :LgBuild inside nvim.
#
# Each binary is written next to its module (for tools that reference it by
# repo path, e.g. kiro agent configs) and installed into the shared directory
# the plugin resolves at runtime, keeping lua/lg/bin.lua in sync:
#
#   $LG_BIN_DIR, else ${XDG_DATA_HOME:-~/.local/share}/nvim/lg/bin

set -euo pipefail

cd "$(dirname "$0")"

if ! command -v go >/dev/null 2>&1; then
	echo "lg: Go is required to build the binaries — https://go.dev/dl" >&2
	exit 1
fi

BIN_DIR="${LG_BIN_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lg/bin}"
mkdir -p "$BIN_DIR"

# <module dir>:<binary name>
targets=(
	"acp:lg-acp"
	"git-mcp:lg-git-mcp"
	"hint-mcp:lg-hint-mcp"
	"lsp:lg-lsp"
	"mcp:lg-mcp"
	"tap:lg-tap"
)

for target in "${targets[@]}"; do
	dir="${target%%:*}"
	name="${target##*:}"
	echo "Building $name..."
	(cd "$dir" && go build -o "$name" .)
	install -m 755 "$dir/$name" "$BIN_DIR/$name"
done

echo "Done — ${#targets[@]} binaries in $BIN_DIR"
