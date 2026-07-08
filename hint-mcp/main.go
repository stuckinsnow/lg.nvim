package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"lg-hint-mcp/internal/hint"
	"lg-hint-mcp/internal/protocol"
)

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

		var req protocol.Request
		if err := json.Unmarshal([]byte(line), &req); err != nil {
			continue
		}

		var resp protocol.Response
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
								"file":       map[string]string{"type": "string", "description": "File path (absolute or relative to project root)"},
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
			getHintsSchema := map[string]any{
				"type": "object",
				"properties": map[string]any{
					"file": map[string]string{"type": "string", "description": "Optional file path to filter by (absolute or relative to project root). Omit to return all published hints."},
				},
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
					{
						"name":        "get_hints",
						"description": "Read back all hints/suggestions currently published (from lg_hint/lg_suggest). Reads from the hint LSP store, so it works even when the file is not open in the editor, and includes the full hover detail. Optionally filter by file.",
						"inputSchema": getHintsSchema,
					},
				},
			}
		case "tools/call":
			var call struct {
				Name      string          `json:"name"`
				Arguments json.RawMessage `json:"arguments"`
			}
			json.Unmarshal(req.Params, &call)

			if call.Name == "get_hints" {
				var args struct {
					File string `json:"file"`
				}
				json.Unmarshal(call.Arguments, &args)
				if args.File != "" && !filepath.IsAbs(args.File) {
					args.File, _ = filepath.Abs(args.File)
				}
				lspResp, err := hint.SendToLSP(map[string]any{"method": "get_hints", "file": args.File})
				if err != nil {
					resp.Result = protocol.ToolResult{
						Content: []protocol.TextContent{{Type: "text", Text: "get_hints failed: " + err.Error()}},
						IsError: true,
					}
				} else {
					var result struct {
						Hints []json.RawMessage `json:"hints"`
					}
					json.Unmarshal(lspResp, &result)
					if len(result.Hints) == 0 {
						resp.Result = protocol.ToolResult{
							Content: []protocol.TextContent{{Type: "text", Text: "No hints currently published."}},
						}
					} else {
						pretty, _ := json.MarshalIndent(result.Hints, "", "  ")
						resp.Result = protocol.ToolResult{
							Content: []protocol.TextContent{{Type: "text", Text: fmt.Sprintf("%d hint(s) currently published:\n\n%s", len(result.Hints), string(pretty))}},
						}
					}
				}
			} else if call.Name != "lg_hint" && call.Name != "lg_suggest" {
				resp.Error = map[string]any{"code": -32601, "message": "unknown tool: " + call.Name}
			} else {
				var args struct {
					Hints []json.RawMessage `json:"hints"`
				}
				json.Unmarshal(call.Arguments, &args)

				// Resolve relative paths to absolute
				resolved := make([]json.RawMessage, len(args.Hints))
				for i, raw := range args.Hints {
					var h map[string]any
					json.Unmarshal(raw, &h)
					if f, ok := h["file"].(string); ok && !filepath.IsAbs(f) {
						h["file"], _ = filepath.Abs(f)
					}
					resolved[i], _ = json.Marshal(h)
				}

				// Filter hints to painted regions if any exist
				regions := hint.GetPaintedRegions()
				var filtered []json.RawMessage
				var outOfScope []string
				if len(regions) > 0 {
					for _, raw := range resolved {
						var h struct {
							File  string `json:"file"`
							Line  int    `json:"line"`
							Match string `json:"match"`
						}
						json.Unmarshal(raw, &h)
						if hint.HintInScope(h.File, h.Line, h.Match, regions) {
							filtered = append(filtered, raw)
						} else {
							outOfScope = append(outOfScope, fmt.Sprintf("line %d of %s is outside painted regions", h.Line, h.File))
						}
					}
				} else {
					filtered = resolved
				}

				if len(filtered) == 0 && len(outOfScope) > 0 {
					var b strings.Builder
					b.WriteString("All hints were outside painted regions — only suggest within painted lines.\n")
					b.WriteString("\nCurrent painted regions:\n")
					for _, r := range regions {
						fmt.Fprintf(&b, "- %s lines %d–%d\n", r.File, r.StartLine, r.EndLine)
					}
					b.WriteString("\nRejected hints:\n")
					for _, f := range outOfScope {
						b.WriteString("- ")
						b.WriteString(f)
						b.WriteByte('\n')
					}
					resp.Result = protocol.ToolResult{
						Content: []protocol.TextContent{{Type: "text", Text: b.String()}},
						IsError: true,
					}
				} else {
					lspResp, err := hint.SendToLSP(map[string]any{"method": "set_hints", "hints": filtered})
					if err != nil {
						resp.Result = protocol.ToolResult{
							Content: []protocol.TextContent{{Type: "text", Text: "hint failed: " + err.Error()}},
							IsError: true,
						}
					} else {
						var result struct {
							Total    int      `json:"total"`
							Matched  int      `json:"matched"`
							Failures []string `json:"failures"`
						}
						json.Unmarshal(lspResp, &result)

						msg := fmt.Sprintf("%d/%d hint(s) matched and published as diagnostics", result.Matched, result.Total)
						var b strings.Builder
						b.WriteString(msg)
						if len(outOfScope) > 0 {
							fmt.Fprintf(&b, "\n\n%d hint(s) were outside painted regions and were dropped.", len(outOfScope))
						}
						if len(result.Failures) > 0 {
							b.WriteString("\n\nFailed to match (these hints were NOT shown to the user — fix and re-call):\n")
							for _, f := range result.Failures {
								b.WriteString("- ")
								b.WriteString(f)
								b.WriteByte('\n')
							}
						}
						resp.Result = protocol.ToolResult{
							Content: []protocol.TextContent{{Type: "text", Text: b.String()}},
							IsError: len(result.Failures) > 0,
						}
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
