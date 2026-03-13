// lg-acp: ACP session manager for lg.nvim
//
// Manages the ACP subprocess lifecycle and sessions. Neovim (Lua) connects
// over a unix socket to create sessions, send prompts, and receive streamed
// events.
//
// Usage:
//   lg-acp --provider kiro --sock /dev/shm/lg-acp.sock
//   lg-acp --provider opencode --sock /dev/shm/lg-acp.sock
package main

import (
	"flag"
	"lg-acp/internal/server"
	"lg-acp/internal/session"
	"log"
	"os"
	"os/signal"
	"syscall"
)

var providers = map[string][]string{
	"kiro":     {"kiro-cli", "acp"},
	"opencode": {"opencode", "acp"},
}

func main() {
	provider := flag.String("provider", "kiro", "ACP provider (kiro or opencode)")
	sockPath := flag.String("sock", "/dev/shm/lg-acp.sock", "Unix socket path")
	flag.Parse()

	cmd, ok := providers[*provider]
	if !ok {
		log.Fatalf("unknown provider: %s", *provider)
	}

	mgr := session.NewManager(cmd, "lg")
	srv := server.New(mgr, *sockPath)

	// Clean shutdown
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
