// Package lsp implements the `lg lsp` hint diagnostic LSP server.
package lsp

import (
	"bufio"
	"encoding/json"
	"os"
	"strings"

	"lg/internal/lsp/hints"
	"lg/internal/lsp/lsptype"
	"lg/internal/lsp/socket"
	"lg/internal/lsp/transport"
)

var sockPath = "/dev/shm/lg-hint.sock"

// Run executes the `lg lsp` subcommand.
func Run(_ []string) {
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
				if d.Range.Start.Line <= p.Position.Line && d.Range.End.Line >= p.Position.Line {
					if hoverRange == nil {
						hoverRange = &d.Range
					}
					if i < len(details) && details[i] != "" && details[i] != d.Message {
						parts = append(parts, details[i])
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
			actions := codeActionsFor(p.TextDocument.URI, p.Range)
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
					if r, ok2 := hints.Replacements[uri]; ok2 && idx < len(r) {
						hints.Replacements[uri] = append(r[:idx], r[idx+1:]...)
					}
					params, _ := json.Marshal(lsptype.PublishDiagnosticsParams{URI: uri, Diagnostics: hints.Diags[uri]})
					transport.Send(lsptype.Message{JSONRPC: "2.0", Method: "textDocument/publishDiagnostics", Params: params})
				}
				hints.Mu.Unlock()
			}
			transport.Send(lsptype.Message{JSONRPC: "2.0", ID: msg.ID, Result: lsptype.NullResult})

		default:
			if msg.ID != nil {
				transport.Send(lsptype.Message{JSONRPC: "2.0", ID: msg.ID, Result: lsptype.NullResult})
			}
		}
	}

	os.Remove(sockPath)
}

func codeActionsFor(uri string, rng lsptype.Range) []map[string]any {
	var actions []map[string]any
	hints.Mu.Lock()
	defer hints.Mu.Unlock()
	repls := hints.Replacements[uri]
	for i, d := range hints.Diags[uri] {
		if d.Range.Start.Line <= rng.End.Line && d.Range.End.Line >= rng.Start.Line {
			if i < len(repls) && repls[i].NewText != "" {
				actions = append(actions, map[string]any{
					"title":       "Apply: " + hints.Truncate(d.Message, 60),
					"kind":        "quickfix",
					"isPreferred": true,
					"edit": map[string]any{
						"changes": map[string][]map[string]any{
							uri: {
								{
									"range":   repls[i].Range,
									"newText": repls[i].NewText,
								},
							},
						},
					},
					"command": map[string]any{
						"title":     "Dismiss hint",
						"command":   "lg.dismissHint",
						"arguments": []any{uri, i},
					},
				})
			}
			actions = append(actions, map[string]any{
				"title": "Dismiss: " + hints.Truncate(d.Message, 60),
				"kind":  "quickfix",
				"command": map[string]any{
					"title":     "Dismiss hint",
					"command":   "lg.dismissHint",
					"arguments": []any{uri, i},
				},
			})
		}
	}
	return actions
}
