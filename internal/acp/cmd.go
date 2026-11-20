// Package acp implements the `lg acp` session manager daemon.
//
// Manages the ACP subprocess lifecycle and sessions. Neovim (Lua) connects
// over a unix socket to create sessions, send prompts, and receive streamed
// events.
package acp

import (
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"

	"lg/internal/acp/server"
	"lg/internal/acp/session"
)

// opencode gets --print-logs because it reports model call failures (usage
// limits, auth) only in its logs; lg acp reads them from stderr.
var providers = map[string][]string{
	"kiro":        {"kiro-cli", "acp", "--agent-engine=v3"},
	"opencode":    {"opencode", "acp", "--print-logs"},
	"antigravity": {"agy", "acp"},
}

// Run executes the `lg acp` subcommand.
func Run(args []string) {
	fs := flag.NewFlagSet("acp", flag.ExitOnError)
	provider := fs.String("provider", "kiro", "ACP provider (kiro, opencode or antigravity)")
	sockPath := fs.String("sock", "/dev/shm/lg-acp.sock", "Unix socket path")
	preview := fs.Bool("preview", false, "Print session preview markdown and exit")
	sessionID := fs.String("session", "", "Session ID for --preview")
	_ = fs.Parse(args)

	if *preview {
		out := server.PreviewSession(*provider, *sessionID)
		if out == "" {
			out = "*No preview available*"
		}
		fmt.Print(out)
		return
	}

	cmd, ok := providers[*provider]
	if !ok {
		log.Fatalf("unknown provider: %s", *provider)
	}

	mgr := session.NewManager(cmd, "lg")
	srv := server.New(mgr, *sockPath, *provider)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sig
		log.Println("acp: shutting down")
		mgr.Terminate()
		srv.Stop()
		os.Exit(0)
	}()

	if err := srv.Start(); err != nil {
		log.Fatalf("acp: %v", err)
	}
}
