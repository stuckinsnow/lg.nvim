// lg: unified backend binary for lg.nvim.
//
// Subcommands:
//
//	lg acp [--provider kiro|opencode|antigravity] [--sock PATH] [--preview --session ID]
//	lg lsp
//	lg mcp [--tools=core,hint,git]
package main

import (
	"fmt"
	"os"

	"lg/internal/acp"
	"lg/internal/lsp"
	"lg/internal/mcp"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}

	switch os.Args[1] {
	case "acp":
		acp.Run(os.Args[2:])
	case "lsp":
		lsp.Run(os.Args[2:])
	case "mcp":
		mcp.Run(os.Args[2:])
	case "-h", "--help", "help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "lg: unknown subcommand %q\n\n", os.Args[1])
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintf(os.Stderr, `usage: lg <subcommand> [flags]

subcommands:
  acp    ACP session manager daemon (--provider, --sock, --preview)
  lsp    Hint LSP server over stdio + /dev/shm/lg-hint.sock
  mcp    MCP tool server over stdio (--tools=core,hint,git)
`)
}
