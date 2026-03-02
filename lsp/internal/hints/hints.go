package hints

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"sync"

	"lg-lsp/internal/lsptype"
	"lg-lsp/internal/transport"
)

// ── Hint socket server ─────────────────────────────────────────────

var Diags = map[string][]lsptype.Diagnostic{}
var Details = map[string][]string{} // parallel to Diags — hover content
var Mu sync.Mutex

func SeverityToLSP(s string) int {
	return 4 // always hint
}

func FileToURI(path string) string {
	return "file://" + path
}

func Truncate(s string, n int) string {
	if len(s) <= n { return s }
	return s[:n] + "…"
}

func isWordChar(c byte) bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

func Publish(hintList []lsptype.Hint) (total int, matched int, failures []string) {
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

	total = len(hintList)
	matched = 0
	grouped := map[string][]lsptype.Diagnostic{}
	groupedDetails := map[string][]string{}
	for _, h := range hintList {
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

		matchOk := true
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
					matchOk = false
					failures = append(failures, fmt.Sprintf("match %q not found on line %d of %s (line content: %q)", h.Match, h.Line, h.File, lines[line]))
				}
			} else {
				matchOk = false
				failures = append(failures, fmt.Sprintf("could not read line %d of %s", h.Line, h.File))
			}
		}

		if matchOk {
			matched++
		}

		if col < 0 {
			col = 0
		}
		if endCol < 0 {
			// No end column — expand to word at col position
			lines := readFile(h.File)
			if lines != nil && line < len(lines) && col < len(lines[line]) {
				l := lines[line]
				start, end_ := col, col
				for start > 0 && isWordChar(l[start-1]) {
					start--
				}
				for end_ < len(l) && isWordChar(l[end_]) {
					end_++
				}
				if end_ > start {
					col = start
					endCol = end_
					endLine = line
				} else {
					endLine = line + 1
					endCol = 0
				}
			} else {
				endLine = endLine + 1
				endCol = 0
			}
		}

		uri := FileToURI(h.File)
		grouped[uri] = append(grouped[uri], lsptype.Diagnostic{
			Range: lsptype.Range{
				Start: lsptype.Position{Line: line, Character: col},
				End:   lsptype.Position{Line: endLine, Character: endCol},
			},
			Severity: SeverityToLSP(h.Severity),
			Source:   "ai",
			Message:  h.Message,
		})
		groupedDetails[uri] = append(groupedDetails[uri], h.Detail)
	}
	Mu.Lock()
	for uri, diags := range grouped {
		existing := Diags[uri]
		existingDetails := Details[uri]
		for i, d := range diags {
			dup := false
			for _, e := range existing {
				if e.Range.Start.Line == d.Range.Start.Line && e.Message == d.Message {
					dup = true
					break
				}
			}
			if !dup {
				existing = append(existing, d)
				detail := ""
				if i < len(groupedDetails[uri]) {
					detail = groupedDetails[uri][i]
				}
				existingDetails = append(existingDetails, detail)
			}
		}
		Diags[uri] = existing
		Details[uri] = existingDetails
	}
	for uri := range grouped {
		params, _ := json.Marshal(lsptype.PublishDiagnosticsParams{URI: uri, Diagnostics: Diags[uri]})
		transport.Send(lsptype.Message{JSONRPC: "2.0", Method: "textDocument/publishDiagnostics", Params: params})
	}
	Mu.Unlock()
	return
}

func ClearAll() {
	// Send empty diagnostics — client clears them
	// We don't track open files, so we rely on the Lua side to call clear per-file
	// But we can publish empty for any file the Lua side tells us about
}
