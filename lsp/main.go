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
	Detail    string `json:"detail"`
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

var storedDiags = map[string][]diagnostic{}
var storedDetails = map[string][]string{} // parallel to storedDiags — hover content
var diagMu sync.Mutex

func severityToLSP(s string) int {
	return 3 // always info
}

func fileToURI(path string) string {
	return "file://" + path
}

func truncate(s string, n int) string {
	if len(s) <= n { return s }
	return s[:n] + "…"
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
	groupedDetails := map[string][]string{}
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
		groupedDetails[uri] = append(groupedDetails[uri], h.Detail)
	}
	diagMu.Lock()
	for uri, diags := range grouped {
		storedDiags[uri] = append(storedDiags[uri], diags...)
		storedDetails[uri] = append(storedDetails[uri], groupedDetails[uri]...)
	}
	for uri := range grouped {
		params, _ := json.Marshal(publishDiagnosticsParams{URI: uri, Diagnostics: storedDiags[uri]})
		sendLSP(lspMessage{JSONRPC: "2.0", Method: "textDocument/publishDiagnostics", Params: params})
	}
	diagMu.Unlock()
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
						diagMu.Lock()
						if len(req.Hints) > 0 {
							seen := map[string]bool{}
							for _, h := range req.Hints {
								uri := fileToURI(h.File)
								if !seen[uri] {
									seen[uri] = true
									delete(storedDiags, uri)
								delete(storedDetails, uri)
									params, _ := json.Marshal(publishDiagnosticsParams{URI: uri, Diagnostics: []diagnostic{}})
									sendLSP(lspMessage{JSONRPC: "2.0", Method: "textDocument/publishDiagnostics", Params: params})
								}
							}
						} else {
							for uri := range storedDiags {
								params, _ := json.Marshal(publishDiagnosticsParams{URI: uri, Diagnostics: []diagnostic{}})
								sendLSP(lspMessage{JSONRPC: "2.0", Method: "textDocument/publishDiagnostics", Params: params})
							}
							storedDiags = map[string][]diagnostic{}
							storedDetails = map[string][]string{}
						}
						diagMu.Unlock()
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
						"textDocumentSync":  1,
						"hoverProvider":     true,
						"codeActionProvider": true,
						"executeCommandProvider": map[string]any{
							"commands": []string{"lg.dismissHint"},
						},
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
			// no-op

		case "textDocument/hover":
			var p struct {
				TextDocument struct{ URI string `json:"uri"` } `json:"textDocument"`
				Position     position                          `json:"position"`
			}
			json.Unmarshal(msg.Params, &p)
			var parts []string
			diagMu.Lock()
			diags := storedDiags[p.TextDocument.URI]
			details := storedDetails[p.TextDocument.URI]
			for i, d := range diags {
				if d.Range.Start.Line <= p.Position.Line && d.Range.End.Line >= p.Position.Line &&
					(d.Range.Start.Line < p.Position.Line || d.Range.Start.Character <= p.Position.Character) &&
					(d.Range.End.Line > p.Position.Line || d.Range.End.Character >= p.Position.Character) {
					if i < len(details) && details[i] != "" {
						parts = append(parts, details[i])
					} else {
						parts = append(parts, d.Message)
					}
				}
			}
			diagMu.Unlock()
			if len(parts) > 0 {
				combined := strings.Join(parts, "\n\n---\n\n")
				result, _ := json.Marshal(map[string]any{
					"contents": map[string]string{"kind": "markdown", "value": combined},
				})
				sendLSP(lspMessage{JSONRPC: "2.0", ID: msg.ID, Result: json.RawMessage(result)})
			} else {
				sendLSP(lspMessage{JSONRPC: "2.0", ID: msg.ID, Result: nil})
			}

		case "textDocument/codeAction":
			var p struct {
				TextDocument struct{ URI string `json:"uri"` } `json:"textDocument"`
				Range        lspRange                          `json:"range"`
			}
			json.Unmarshal(msg.Params, &p)
			var actions []map[string]any
			diagMu.Lock()
			for i, d := range storedDiags[p.TextDocument.URI] {
				if d.Range.Start.Line <= p.Range.End.Line && d.Range.End.Line >= p.Range.Start.Line {
					actions = append(actions, map[string]any{
						"title": "Dismiss: " + truncate(d.Message, 60),
						"kind":  "quickfix",
						"command": map[string]any{
							"title":   "Dismiss hint",
							"command": "lg.dismissHint",
							"arguments": []any{p.TextDocument.URI, i},
						},
					})
				}
			}
			diagMu.Unlock()
			sendLSP(lspMessage{JSONRPC: "2.0", ID: msg.ID, Result: actions})

		case "workspace/executeCommand":
			var p struct {
				Command   string `json:"command"`
				Arguments []json.RawMessage `json:"arguments"`
			}
			json.Unmarshal(msg.Params, &p)
			if p.Command == "lg.dismissHint" && len(p.Arguments) == 2 {
				var uri string
				var idx int
				json.Unmarshal(p.Arguments[0], &uri)
				json.Unmarshal(p.Arguments[1], &idx)
				diagMu.Lock()
				if diags, ok := storedDiags[uri]; ok && idx >= 0 && idx < len(diags) {
					storedDiags[uri] = append(diags[:idx], diags[idx+1:]...)
					if d, ok2 := storedDetails[uri]; ok2 && idx < len(d) {
						storedDetails[uri] = append(d[:idx], d[idx+1:]...)
					}
					params, _ := json.Marshal(publishDiagnosticsParams{URI: uri, Diagnostics: storedDiags[uri]})
					sendLSP(lspMessage{JSONRPC: "2.0", Method: "textDocument/publishDiagnostics", Params: params})
				}
				diagMu.Unlock()
			}
			sendLSP(lspMessage{JSONRPC: "2.0", ID: msg.ID, Result: nil})

		default:
			if msg.ID != nil {
				// Unknown request — respond with method not found
				sendLSP(lspMessage{JSONRPC: "2.0", ID: msg.ID, Result: nil})
			}
		}
	}

	os.Remove(sockPath)
}
