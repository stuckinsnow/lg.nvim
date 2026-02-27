package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
)

// ── LSP types ──────────────────────────────────────────────────────

type lspMessage struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      any             `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
	Result  any             `json:"result,omitempty"`
}

type position struct {
	Line      int `json:"line"`
	Character int `json:"character"`
}

type lspRange struct {
	Start position `json:"start"`
	End   position `json:"end"`
}

type diagnostic struct {
	Range    lspRange `json:"range"`
	Severity int      `json:"severity"`
	Source   string   `json:"source"`
	Message  string   `json:"message"`
}

type publishDiagnosticsParams struct {
	URI         string       `json:"uri"`
	Diagnostics []diagnostic `json:"diagnostics"`
}

// ── Hint socket types ──────────────────────────────────────────────

type hint struct {
	File      string `json:"file"`
	Line      int    `json:"line"`
	EndLine   int    `json:"end_line"`
	Column    int    `json:"column"`
	EndColumn int    `json:"end_column"`
	Match     string `json:"match"`
	Message   string `json:"message"`
	Severity  string `json:"severity"`
}

type hintRequest struct {
	Method string `json:"method"`
	Hints  []hint `json:"hints"`
}

// ── State ──────────────────────────────────────────────────────────

var (
	mu          sync.Mutex
	stdout      *bufio.Writer
	initialized bool
	sockPath    = "/dev/shm/lg-hint.sock"
)

// ── LSP I/O ────────────────────────────────────────────────────────

func sendLSP(msg lspMessage) {
	data, _ := json.Marshal(msg)
	mu.Lock()
	fmt.Fprintf(stdout, "Content-Length: %d\r\n\r\n%s", len(data), data)
	stdout.Flush()
	mu.Unlock()
}

func readLSP(reader *bufio.Reader) ([]byte, error) {
	var contentLen int
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			return nil, err
		}
		line = strings.TrimSpace(line)
		if line == "" {
			break
		}
		if strings.HasPrefix(line, "Content-Length:") {
			n, _ := strconv.Atoi(strings.TrimSpace(line[15:]))
			contentLen = n
		}
	}
	if contentLen == 0 {
		return nil, fmt.Errorf("no content-length")
	}
	body := make([]byte, contentLen)
	n := 0
	for n < contentLen {
		r, err := reader.Read(body[n:])
		if err != nil {
			return nil, err
		}
		n += r
	}
	return body, nil
}

// ── Hint socket server ─────────────────────────────────────────────

func severityToLSP(s string) int {
	return 3 // always info
}

func fileToURI(path string) string {
	return "file://" + path
}

func publishHints(hints []hint) {
	// Cache file lines
	fileLines := map[string][]string{}
	readFile := func(path string) []string {
		if lines, ok := fileLines[path]; ok {
			return lines
		}
		data, err := os.ReadFile(path)
		if err != nil {
			fileLines[path] = nil
			return nil
		}
		lines := strings.Split(string(data), "\n")
		fileLines[path] = lines
		return lines
	}

	grouped := map[string][]diagnostic{}
	for _, h := range hints {
		line := h.Line - 1
		if line < 0 {
			line = 0
		}
		endLine := h.EndLine - 1
		if endLine < line {
			endLine = line
		}

		col := h.Column - 1
		endCol := h.EndColumn - 1

		// If match is provided, find it on the line to get exact columns
		if h.Match != "" && col < 0 {
			lines := readFile(h.File)
			if lines != nil && line < len(lines) {
				idx := strings.Index(lines[line], h.Match)
				if idx >= 0 {
					col = idx
					endCol = idx + len(h.Match)
					endLine = line
				} else {
					fmt.Fprintf(os.Stderr, "lg-lsp: match %q not found on line %d of %s\n", h.Match, h.Line, h.File)
				}
			} else {
				fmt.Fprintf(os.Stderr, "lg-lsp: could not read line %d of %s\n", h.Line, h.File)
			}
		}

		if col < 0 {
			col = 0
		}
		if endCol < 0 {
			endLine = endLine + 1
			endCol = 0
		}

		uri := fileToURI(h.File)
		grouped[uri] = append(grouped[uri], diagnostic{
			Range: lspRange{
				Start: position{Line: line, Character: col},
				End:   position{Line: endLine, Character: endCol},
			},
			Severity: severityToLSP(h.Severity),
			Source:   "ai",
			Message:  h.Message,
		})
	}
	for uri, diags := range grouped {
		params, _ := json.Marshal(publishDiagnosticsParams{URI: uri, Diagnostics: diags})
		sendLSP(lspMessage{JSONRPC: "2.0", Method: "textDocument/publishDiagnostics", Params: params})
	}
}

func clearAll() {
	// Send empty diagnostics — client clears them
	// We don't track open files, so we rely on the Lua side to call clear per-file
	// But we can publish empty for any file the Lua side tells us about
}

func startHintSocket() {
	os.Remove(sockPath)
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "hint socket: %v\n", err)
		return
	}
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				scanner := bufio.NewScanner(c)
				scanner.Buffer(make([]byte, 1024*1024), 1024*1024)
				for scanner.Scan() {
					var req hintRequest
					if err := json.Unmarshal(scanner.Bytes(), &req); err != nil {
						c.Write([]byte(`{"error":"invalid json"}` + "\n"))
						continue
					}
					switch req.Method {
					case "set_hints":
						publishHints(req.Hints)
						c.Write([]byte(`{"ok":true}` + "\n"))
					case "clear":
						// Publish empty diagnostics for files in hints
						if len(req.Hints) > 0 {
							seen := map[string]bool{}
							for _, h := range req.Hints {
								uri := fileToURI(h.File)
								if !seen[uri] {
									seen[uri] = true
									params, _ := json.Marshal(publishDiagnosticsParams{URI: uri, Diagnostics: []diagnostic{}})
									sendLSP(lspMessage{JSONRPC: "2.0", Method: "textDocument/publishDiagnostics", Params: params})
								}
							}
						}
						c.Write([]byte(`{"ok":true}` + "\n"))
					default:
						c.Write([]byte(`{"error":"unknown method"}` + "\n"))
					}
				}
			}(conn)
		}
	}()
}

// ── Main LSP loop ──────────────────────────────────────────────────

func main() {
	if p := os.Getenv("LG_HINT_SOCK"); p != "" {
		sockPath = p
	}

	stdout = bufio.NewWriter(os.Stdout)
	reader := bufio.NewReader(os.Stdin)

	startHintSocket()

	for {
		body, err := readLSP(reader)
		if err != nil {
			break
		}

		var msg lspMessage
		if err := json.Unmarshal(body, &msg); err != nil {
			continue
		}

		switch msg.Method {
		case "initialize":
			sendLSP(lspMessage{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Result: map[string]any{
					"capabilities": map[string]any{
						"textDocumentSync": 1, // full sync
					},
					"serverInfo": map[string]any{
						"name":    "lg-hint",
						"version": "0.1.0",
					},
				},
			})
			initialized = true

		case "initialized":
			// no-op

		case "shutdown":
			sendLSP(lspMessage{JSONRPC: "2.0", ID: msg.ID, Result: nil})

		case "exit":
			os.Remove(sockPath)
			os.Exit(0)

		case "textDocument/didOpen", "textDocument/didChange", "textDocument/didClose":
			// no-op — we don't need to track documents

		default:
			if msg.ID != nil {
				// Unknown request — respond with method not found
				sendLSP(lspMessage{JSONRPC: "2.0", ID: msg.ID, Result: nil})
			}
		}
	}

	os.Remove(sockPath)
}
