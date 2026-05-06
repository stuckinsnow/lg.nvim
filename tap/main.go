// lg-tap: ACP passthrough proxy that taps stdout for tool calls
// and forwards them to neovim over a unix socket.
//
// Usage (set as KIRO_AGENT_PATH):
//   KIRO_AGENT_PATH=lg-tap REAL_KIRO_AGENT=kiro-cli kiro-cli chat --tui
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"sync"
	"syscall"
)

var sock = flag.String("sock", "/dev/shm/lg-tap.sock", "Unix socket to forward events to")
var logFile = flag.String("log", "/tmp/acp-tap/tap.jsonl", "Log file for all messages")

func main() {
	flag.Parse()

	agent := os.Getenv("REAL_KIRO_AGENT")
	if agent == "" {
		agent = "kiro-cli"
	}

	// Pass through all args we received (TUI passes "acp" etc.)
	args := flag.Args()
	cmd := exec.Command(agent, args...)
	cmd.Stderr = os.Stderr

	stdin, _ := cmd.StdinPipe()
	stdout, _ := cmd.StdoutPipe()

	if err := cmd.Start(); err != nil {
		log.Fatalf("lg-tap: failed to start agent: %v", err)
	}

	// Forward our stdin to agent's stdin (with logging)
	go func() {
		os.MkdirAll("/tmp/acp-tap", 0755)
		sf, _ := os.OpenFile("/tmp/acp-tap/stdin.jsonl", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
		defer func() { if sf != nil { sf.Close() } }()

		scanner := bufio.NewScanner(os.Stdin)
		scanner.Buffer(make([]byte, 1024*1024), 1024*1024)
		for scanner.Scan() {
			line := scanner.Bytes()
			stdin.Write(line)
			stdin.Write([]byte("\n"))
			if sf != nil {
				sf.Write(line)
				sf.Write([]byte("\n"))
			}
		}
		stdin.Close()
	}()

	// Read agent stdout, forward to our stdout, and tap events
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		tap(stdout, os.Stdout)
	}()

	// Clean shutdown
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sig
		cmd.Process.Signal(syscall.SIGTERM)
	}()

	wg.Wait()
	cmd.Wait()
	os.Exit(cmd.ProcessState.ExitCode())
}

// tap reads from src, writes everything to dst (passthrough),
// and parses JSON lines to forward interesting events to the socket.
func tap(src io.Reader, dst io.Writer) {
	os.MkdirAll("/tmp/acp-tap", 0755)
	lf, _ := os.OpenFile(*logFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	defer func() { if lf != nil { lf.Close() } }()

	scanner := bufio.NewScanner(src)
	scanner.Buffer(make([]byte, 1024*1024), 1024*1024)

	for scanner.Scan() {
		line := scanner.Bytes()
		// Always forward
		dst.Write(line)
		dst.Write([]byte("\n"))

		if lf != nil {
			lf.Write(line)
			lf.Write([]byte("\n"))
		}

		// Try to parse and forward interesting events
		if len(line) == 0 || line[0] != '{' {
			continue
		}
		var msg struct {
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
			Result json.RawMessage `json:"result"`
		}
		if json.Unmarshal(line, &msg) != nil {
			continue
		}

		// Forward result messages with stopReason
		if msg.Result != nil {
			var result struct {
				StopReason string `json:"stopReason"`
			}
			if json.Unmarshal(msg.Result, &result) == nil && result.StopReason != "" {
				forward(line)
			}
			continue
		}

		switch msg.Method {
		case "fs/write_text_file", "fs/read_text_file":
			forward(line)
		case "session/update":
			// Check sessionUpdate type inside
			var params struct {
				Update json.RawMessage `json:"update"`
			}
			if json.Unmarshal(msg.Params, &params) != nil {
				continue
			}
			var update struct {
				SessionUpdate string `json:"sessionUpdate"`
			}
			if json.Unmarshal(params.Update, &update) != nil {
				continue
			}
			switch update.SessionUpdate {
			case "tool_call", "tool_call_update":
				forward(line)
			}
		case "session/request_permission":
			forward(line)
		}
	}
}

func forward(data []byte) {
	conn, err := net.Dial("unix", *sock)
	if err != nil {
		return // neovim not listening, skip
	}
	defer conn.Close()
	conn.Write(data)
	conn.Write([]byte("\n"))
}
