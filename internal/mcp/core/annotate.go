package core

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"

	"lg/internal/mcp/nvim"
	"lg/internal/mcp/protocol"
	"lg/internal/linematch"
)

// lg_annotate publishes annotations through the lg-hint LSP socket directly.
// It lives in lg-mcp (not only lg-hint-mcp) because some providers
// (antigravity) only get the lg MCP server attached, and because the AI needs
// it in the normal edit mode right after making changes.

func hintSockPath() string {
	if p := os.Getenv("LG_HINT_SOCK"); p != "" {
		return p
	}
	return "/dev/shm/lg-hint.sock"
}

func sendToHintLSP(req any) ([]byte, error) {
	conn, err := net.Dial("unix", hintSockPath())
	if err != nil {
		return nil, fmt.Errorf("connect to hint LSP: %w", err)
	}
	defer func() { _ = conn.Close() }()
	data, _ := json.Marshal(req)
	if _, err := conn.Write(append(data, '\n')); err != nil {
		return nil, err
	}
	return bufio.NewReader(conn).ReadBytes('\n')
}

// bufferLines reads a file through Neovim so unsaved edits (e.g. fresh
// paint_edit changes) are seen. Falls back to disk.
func bufferLines(path string) []string {
	resp, err := nvim.SendToNeovim(map[string]any{"method": "read_buffer", "path": path})
	if err == nil {
		var r struct {
			Content string `json:"content"`
			Error   string `json:"error"`
		}
		if json.Unmarshal(resp, &r) == nil && r.Error == "" {
			return strings.Split(r.Content, "\n")
		}
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	return strings.Split(string(data), "\n")
}

type annotation struct {
	File      string `json:"file"`
	Line      int    `json:"line"`
	EndLine   int    `json:"end_line,omitempty"`
	Match     string `json:"match,omitempty"`
	Column    int    `json:"column,omitempty"`
	EndColumn int    `json:"end_column,omitempty"`
	Message   string `json:"message"`
	Detail    string `json:"detail,omitempty"`
	Severity  string `json:"severity"`
}

func handleAnnotate(raw json.RawMessage) protocol.ToolResult {
	var args struct {
		Annotations []annotation `json:"annotations"`
	}
	if err := json.Unmarshal(raw, &args); err != nil {
		return toolErr("invalid arguments: " + err.Error())
	}
	if len(args.Annotations) == 0 {
		return toolErr("annotations is empty — pass at least one annotation")
	}

	cache := map[string][]string{}
	var failures []string
	hints := make([]annotation, 0, len(args.Annotations))
	for _, a := range args.Annotations {
		if a.File == "" || a.Line <= 0 || strings.TrimSpace(a.Message) == "" {
			failures = append(failures, fmt.Sprintf("annotation needs file, line (>=1) and message: %+v", a))
			continue
		}
		if !filepath.IsAbs(a.File) {
			a.File, _ = filepath.Abs(a.File)
		}
		if a.Severity == "" {
			a.Severity = "info"
		}
		if a.EndLine < a.Line {
			a.EndLine = a.Line
		}
		// Resolve match against the live buffer; the LSP itself only sees disk.
		if a.Match != "" && a.Column == 0 {
			lines, ok := cache[a.File]
			if !ok {
				lines = bufferLines(a.File)
				cache[a.File] = lines
			}
			if lines == nil {
				failures = append(failures, "could not read "+a.File)
				continue
			}
			l, c, ec, found := linematch.FindNearestLine(lines, a.Line-1, a.Match)
			if !found {
				failures = append(failures, fmt.Sprintf("match %q not found near line %d of %s", a.Match, a.Line, a.File))
				continue
			}
			span := a.EndLine - a.Line
			a.Line = l + 1
			a.EndLine = a.Line + span
			a.Column = c + 1
			a.EndColumn = ec + 1
			if span > 0 && a.EndLine-1 < len(lines) {
				a.EndColumn = len(lines[a.EndLine-1]) + 1
			} else if ec-c <= 1 && l < len(lines) {
				a.EndColumn = len(lines[l]) + 1
			}
			a.Match = ""
		}
		hints = append(hints, a)
	}

	var published int
	if len(hints) > 0 {
		resp, err := sendToHintLSP(map[string]any{"method": "set_hints", "hints": hints})
		if err != nil {
			return toolErr("annotate failed: " + err.Error())
		}
		var result struct {
			Matched  int      `json:"matched"`
			Failures []string `json:"failures"`
		}
		_ = json.Unmarshal(resp, &result)
		published = result.Matched
		failures = append(failures, result.Failures...)
	}

	var b strings.Builder
	fmt.Fprintf(&b, "%d/%d annotation(s) published", published, len(args.Annotations))
	if len(failures) > 0 {
		b.WriteString("\n\nFailed (NOT shown to the user — fix and re-call with only these):\n")
		for _, f := range failures {
			b.WriteString("- " + f + "\n")
		}
	}
	return protocol.ToolResult{
		Content: []protocol.TextContent{{Type: "text", Text: b.String()}},
		IsError: len(failures) > 0,
	}
}

func toolErr(msg string) protocol.ToolResult {
	return protocol.ToolResult{Content: []protocol.TextContent{{Type: "text", Text: msg}}, IsError: true}
}

func annotateToolDef() protocol.ToolDef {
	f := false
	return protocol.ToolDef{
		Name: "lg_annotate",
		Description: "Annotate code changes in the editor. Each annotation shows as an inline diagnostic (hover for detail) and is added to the user's location list. " +
			"Use AFTER making edits to explain each change. Line numbers refer to the file AFTER your edits. Send ALL annotations in one call.",
		InputSchema: protocol.ToolSchema{
			Type: "object",
			Properties: map[string]any{
				"annotations": map[string]any{
					"type": "array",
					"items": map[string]any{
						"type": "object",
						"properties": map[string]any{
							"file":     map[string]string{"type": "string", "description": "File path (absolute or relative to project root)"},
							"line":     map[string]string{"type": "integer", "description": "Start line (1-based) in the current file"},
							"end_line": map[string]string{"type": "integer", "description": "End line (1-based, inclusive)"},
							"match":    map[string]string{"type": "string", "description": "Exact text on that line to underline (recommended — tolerates small line offsets)"},
							"message":  map[string]string{"type": "string", "description": "One short line: what changed and why"},
							"detail":   map[string]string{"type": "string", "description": "Optional longer explanation shown on hover (markdown)"},
							"severity": map[string]string{"type": "string", "description": "info (default), hint, warning, or error"},
						},
						"required":             []string{"file", "line", "message"},
						"additionalProperties": false,
					},
				},
			},
			Required:             []string{"annotations"},
			AdditionalProperties: &f,
		},
	}
}
