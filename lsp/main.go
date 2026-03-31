package main

import (
	"bufio"
	"encoding/json"
	"lg-lsp/internal/hints"
	"lg-lsp/internal/lsptype"
	"lg-lsp/internal/socket"
	"lg-lsp/internal/transport"
	"os"
	"strings"
)

var sockPath = "/dev/shm/lg-hint.sock"

func main() {
	if p := os.Getenv("LG_HINT_SOCK"); p != "" {
		sockPath = p
	}

	transport.Writer = bufio.NewWriter(os.Stdout)
	reader := bufio.NewReader(os.Stdin)

	socket.Start(sockPath)

	for {
		body, err := transport.Read(reader)
		if err != nil {
			break
		}

		var msg lsptype.Message
		if err := json.Unmarshal(body, &msg); err != nil {
			continue
		}

		switch msg.Method {
		case "initialize":
			transport.Send(lsptype.Message{
				JSONRPC: "2.0",
				ID:      msg.ID,
				Result: map[string]any{
					"capabilities": map[string]any{
						"textDocumentSync":   1,
						"hoverProvider":      true,
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

		case "initialized":
			// no-op

		case "shutdown":
			transport.Send(lsptype.Message{JSONRPC: "2.0", ID: msg.ID, Result: lsptype.NullResult})

		case "exit":
			os.Remove(sockPath)
			os.Exit(0)

		case "textDocument/didOpen", "textDocument/didChange", "textDocument/didClose":
			// no-op

		case "textDocument/hover":
			var p struct {
				TextDocument struct {
					URI string `json:"uri"`
				} `json:"textDocument"`
				Position lsptype.Position `json:"position"`
			}
			json.Unmarshal(msg.Params, &p)
			var parts []string
			var hoverRange *lsptype.Range
			hints.Mu.Lock()
			diags := hints.Diags[p.TextDocument.URI]
			details := hints.Details[p.TextDocument.URI]
			for i, d := range diags {
				if d.Range.Start.Line <= p.Position.Line && d.Range.End.Line >= p.Position.Line &&
					(d.Range.Start.Line < p.Position.Line || d.Range.Start.Character <= p.Position.Character) &&
					(d.Range.End.Line > p.Position.Line || d.Range.End.Character >= p.Position.Character) {
					if hoverRange == nil {
						hoverRange = &d.Range
					}
					if i < len(details) && details[i] != "" {
						parts = append(parts, details[i])
					} else {
						parts = append(parts, d.Message)
					}
				}
			}
			hints.Mu.Unlock()
			if len(parts) > 0 {
				combined := strings.Join(parts, "\n\n---\n\n")
				resp := map[string]any{
					"contents": map[string]string{"kind": "markdown", "value": combined},
				}
				if hoverRange != nil {
					resp["range"] = hoverRange
				}
				result, _ := json.Marshal(resp)
				transport.Send(lsptype.Message{JSONRPC: "2.0", ID: msg.ID, Result: json.RawMessage(result)})
			} else {
				transport.Send(lsptype.Message{JSONRPC: "2.0", ID: msg.ID, Result: lsptype.NullResult})
			}

		case "textDocument/codeAction":
			var p struct {
				TextDocument struct {
					URI string `json:"uri"`
				} `json:"textDocument"`
				Range lsptype.Range `json:"range"`
			}
			json.Unmarshal(msg.Params, &p)
			var actions []map[string]any
			hints.Mu.Lock()
			for i, d := range hints.Diags[p.TextDocument.URI] {
				if d.Range.Start.Line <= p.Range.End.Line && d.Range.End.Line >= p.Range.Start.Line {
					actions = append(actions, map[string]any{
						"title": "Dismiss: " + hints.Truncate(d.Message, 60),
						"kind":  "quickfix",
						"command": map[string]any{
							"title":     "Dismiss hint",
							"command":   "lg.dismissHint",
							"arguments": []any{p.TextDocument.URI, i},
						},
					})
				}
			}
			hints.Mu.Unlock()
			transport.Send(lsptype.Message{JSONRPC: "2.0", ID: msg.ID, Result: actions})

		case "workspace/executeCommand":
			var p struct {
				Command   string            `json:"command"`
				Arguments []json.RawMessage `json:"arguments"`
			}
			json.Unmarshal(msg.Params, &p)
			if p.Command == "lg.dismissHint" && len(p.Arguments) == 2 {
				var uri string
				var idx int
				json.Unmarshal(p.Arguments[0], &uri)
				json.Unmarshal(p.Arguments[1], &idx)
				hints.Mu.Lock()
				if diags, ok := hints.Diags[uri]; ok && idx >= 0 && idx < len(diags) {
					hints.Diags[uri] = append(diags[:idx], diags[idx+1:]...)
					if d, ok2 := hints.Details[uri]; ok2 && idx < len(d) {
						hints.Details[uri] = append(d[:idx], d[idx+1:]...)
					}
					params, _ := json.Marshal(lsptype.PublishDiagnosticsParams{URI: uri, Diagnostics: hints.Diags[uri]})
					transport.Send(lsptype.Message{JSONRPC: "2.0", Method: "textDocument/publishDiagnostics", Params: params})
				}
				hints.Mu.Unlock()
			}
			transport.Send(lsptype.Message{JSONRPC: "2.0", ID: msg.ID, Result: lsptype.NullResult})

		default:
			if msg.ID != nil {
				// Unknown request — respond with method not found
				transport.Send(lsptype.Message{JSONRPC: "2.0", ID: msg.ID, Result: lsptype.NullResult})
			}
		}
	}

	os.Remove(sockPath)
}
