package hint

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"

	"lg/internal/mcp/protocol"
)

// Defs returns the MCP tool definitions for the hint group.
func Defs() []protocol.ToolDef {
	f := false
	hintSchema := protocol.ToolSchema{
		Type: "object",
		Properties: map[string]any{
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
		Required:             []string{"hints"},
		AdditionalProperties: &f,
	}
	getHintsSchema := protocol.ToolSchema{
		Type: "object",
		Properties: map[string]any{
			"file": map[string]string{"type": "string", "description": "Optional file path to filter by (absolute or relative to project root). Omit to return all published hints."},
		},
		Required:             []string{},
		AdditionalProperties: &f,
	}

	return []protocol.ToolDef{
		{
			Name:        "lg_hint",
			Description: "Publish AI findings as diagnostics in the editor. Hints appear as squiggly underlines with hover messages. Use this to annotate code without editing anything.",
			InputSchema: hintSchema,
		},
		{
			Name:        "lg_suggest",
			Description: "Publish code suggestions as diagnostics in the editor. Each suggestion appears as an underline — the hover message MUST contain a markdown code block showing the recommended replacement code. Use this to propose concrete code changes without editing anything.",
			InputSchema: hintSchema,
		},
		{
			Name:        "get_hints",
			Description: "Read back all hints/suggestions currently published (from lg_hint/lg_suggest). Reads from the hint LSP store, so it works even when the file is not open in the editor, and includes the full hover detail. Optionally filter by file.",
			InputSchema: getHintsSchema,
		},
	}
}

// Call handles a hint tool invocation. handled is false when name is not a hint tool.
func Call(name string, rawArgs json.RawMessage) (any, bool, error) {
	switch name {
	case "get_hints":
		var args struct {
			File string `json:"file"`
		}
		_ = json.Unmarshal(rawArgs, &args)
		if args.File != "" && !filepath.IsAbs(args.File) {
			args.File, _ = filepath.Abs(args.File)
		}
		lspResp, err := SendToLSP(map[string]any{"method": "get_hints", "file": args.File})
		if err != nil {
			return protocol.ToolResult{
				Content: []protocol.TextContent{{Type: "text", Text: "get_hints failed: " + err.Error()}},
				IsError: true,
			}, true, nil
		}
		var result struct {
			Hints []json.RawMessage `json:"hints"`
		}
		_ = json.Unmarshal(lspResp, &result)
		if len(result.Hints) == 0 {
			return protocol.ToolResult{
				Content: []protocol.TextContent{{Type: "text", Text: "No hints currently published."}},
			}, true, nil
		}
		pretty, _ := json.MarshalIndent(result.Hints, "", "  ")
		return protocol.ToolResult{
			Content: []protocol.TextContent{{Type: "text", Text: fmt.Sprintf("%d hint(s) currently published:\n\n%s", len(result.Hints), string(pretty))}},
		}, true, nil

	case "lg_hint", "lg_suggest":
		var args struct {
			Hints []json.RawMessage `json:"hints"`
		}
		_ = json.Unmarshal(rawArgs, &args)

		resolved := make([]json.RawMessage, len(args.Hints))
		for i, raw := range args.Hints {
			var h map[string]any
			_ = json.Unmarshal(raw, &h)
			if f, ok := h["file"].(string); ok && !filepath.IsAbs(f) {
				h["file"], _ = filepath.Abs(f)
			}
			resolved[i], _ = json.Marshal(h)
		}

		regions := GetPaintedRegions()
		var filtered []json.RawMessage
		var outOfScope []string
		if len(regions) > 0 {
			for _, raw := range resolved {
				var h struct {
					File  string `json:"file"`
					Line  int    `json:"line"`
					Match string `json:"match"`
				}
				_ = json.Unmarshal(raw, &h)
				if HintInScope(h.File, h.Line, h.Match, regions) {
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
			return protocol.ToolResult{
				Content: []protocol.TextContent{{Type: "text", Text: b.String()}},
				IsError: true,
			}, true, nil
		}

		lspResp, err := SendToLSP(map[string]any{"method": "set_hints", "hints": filtered})
		if err != nil {
			return protocol.ToolResult{
				Content: []protocol.TextContent{{Type: "text", Text: "hint failed: " + err.Error()}},
				IsError: true,
			}, true, nil
		}
		var result struct {
			Total    int      `json:"total"`
			Matched  int      `json:"matched"`
			Failures []string `json:"failures"`
		}
		_ = json.Unmarshal(lspResp, &result)

		var b strings.Builder
		fmt.Fprintf(&b, "%d/%d hint(s) matched and published as diagnostics", result.Matched, result.Total)
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
		return protocol.ToolResult{
			Content: []protocol.TextContent{{Type: "text", Text: b.String()}},
			IsError: len(result.Failures) > 0,
		}, true, nil

	default:
		return nil, false, nil
	}
}
