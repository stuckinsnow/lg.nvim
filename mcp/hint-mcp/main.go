package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strings"
)

var hintSockPath string

func init() {
	hintSockPath = os.Getenv("LG_HINT_SOCK")
	if hintSockPath == "" {
		hintSockPath = "/dev/shm/lg-hint.sock"
	}
}

type jsonRPCRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      any             `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type jsonRPCResponse struct {
	JSONRPC string `json:"jsonrpc"`
	ID      any    `json:"id"`
	Result  any    `json:"result,omitempty"`
	Error   any    `json:"error,omitempty"`
}

type textContent struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

type toolResult struct {
	Content []textContent `json:"content"`
	IsError bool          `json:"isError,omitempty"`
}

func sendToLSP(req any) ([]byte, error) {
	conn, err := net.Dial("unix", hintSockPath)
	if err != nil {
		return nil, fmt.Errorf("connect to hint LSP: %w", err)
	}
	defer conn.Close()
	data, _ := json.Marshal(req)
	data = append(data, '\n')
	if _, err := conn.Write(data); err != nil {
		return nil, err
	}
	reader := bufio.NewReader(conn)
	return reader.ReadBytes('\n')
}

func main() {
	f := false
	reader := bufio.NewReader(os.Stdin)

	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			break
		}
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}

		var req jsonRPCRequest
		if err := json.Unmarshal([]byte(line), &req); err != nil {
			continue
		}

		var resp jsonRPCResponse
		resp.JSONRPC = "2.0"
		resp.ID = req.ID

		switch req.Method {
		case "initialize":
			resp.Result = map[string]any{
				"protocolVersion": "2024-11-05",
				"capabilities":    map[string]any{"tools": map[string]any{}},
				"serverInfo":      map[string]any{"name": "lg-hint-mcp", "version": "0.1.0"},
			}
		case "notifications/initialized":
			continue
		case "tools/list":
			hintSchema := map[string]any{
				"type": "object",
				"properties": map[string]any{
					"hints": map[string]any{
						"type": "array",
						"items": map[string]any{
							"type": "object",
							"properties": map[string]any{
								"file":       map[string]string{"type": "string", "description": "Absolute file path"},
								"line":       map[string]string{"type": "integer", "description": "Start line (1-based)"},
								"end_line":   map[string]string{"type": "integer", "description": "End line (1-based, inclusive)"},
								"match":      map[string]string{"type": "string", "description": "Text to match on the line to auto-calculate exact underline range. Preferred over column."},
								"column":     map[string]string{"type": "integer", "description": "Start column (1-based). Omit if using match."},
								"end_column": map[string]string{"type": "integer", "description": "End column (1-based, exclusive). Omit if using match."},
								"message":    map[string]string{"type": "string", "description": "Short summary shown as inline diagnostic text"},
								"detail":     map[string]string{"type": "string", "description": "Full detail shown on hover (markdown supported). Include code blocks for suggestions. Falls back to message if omitted."},
								"severity":   map[string]string{"type": "string", "description": "One of: error, warning, info, hint"},
							},
							"required":             []string{"file", "line", "message", "severity"},
							"additionalProperties": false,
						},
					},
				},
				"required":             []string{"hints"},
				"additionalProperties": &f,
			}
			resp.Result = map[string]any{
				"tools": []map[string]any{
					{
						"name":        "lg_hint",
						"description": "Publish AI findings as diagnostics in the editor. Hints appear as squiggly underlines with hover messages. Use this to annotate code without editing anything.",
						"inputSchema": hintSchema,
					},
					{
						"name":        "lg_suggest",
						"description": "Publish code suggestions as diagnostics in the editor. Each suggestion appears as an underline — the hover message MUST contain a markdown code block showing the recommended replacement code. Use this to propose concrete code changes without editing anything.",
						"inputSchema": hintSchema,
					},
				},
			}
		case "tools/call":
			var call struct {
				Name      string          `json:"name"`
				Arguments json.RawMessage `json:"arguments"`
			}
			json.Unmarshal(req.Params, &call)

			if call.Name != "lg_hint" && call.Name != "lg_suggest" {
				resp.Error = map[string]any{"code": -32601, "message": "unknown tool: " + call.Name}
			} else {
				var args struct {
					Hints json.RawMessage `json:"hints"`
				}
				json.Unmarshal(call.Arguments, &args)

				_, err := sendToLSP(map[string]any{"method": "set_hints", "hints": json.RawMessage(args.Hints)})
				if err != nil {
					resp.Result = toolResult{
						Content: []textContent{{Type: "text", Text: "hint failed: " + err.Error()}},
						IsError: true,
					}
				} else {
					// Count hints
					var hints []json.RawMessage
					json.Unmarshal(args.Hints, &hints)
					resp.Result = toolResult{
						Content: []textContent{{Type: "text", Text: fmt.Sprintf("%d hint(s) published as diagnostics", len(hints))}},
					}
				}
			}
		default:
			resp.Error = map[string]any{"code": -32601, "message": "method not found: " + req.Method}
		}

		out, _ := json.Marshal(resp)
		fmt.Println(string(out))
	}
}
