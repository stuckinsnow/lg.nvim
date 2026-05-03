package main

import (
	"encoding/json"
	"fmt"
	"lg-mcp/internal/nvim"
	"net"
	"os"
	"strings"
	"testing"
)

func TestSearchFormatting(t *testing.T) {
	results := []struct {
		File      string
		StartLine int
		EndLine   int
		Score     float64
		Content   string
	}{
		{File: "src/auth.go", StartLine: 10, EndLine: 25, Score: 0.85, Content: "func Login(user, pass string) error {\n\treturn nil\n}"},
		{File: "src/session.go", StartLine: 1, EndLine: 20, Score: 0.78, Content: "type Session struct {\n\tToken string\n}"},
		{File: "pkg/middleware.ts", StartLine: 1, EndLine: 15, Score: 0.72, Content: "export function authMiddleware(req: Request) {\n  return next()\n}"},
		{File: "src/handler.go", StartLine: 30, EndLine: 50, Score: 0.65, Content: "func HandleLogin(w http.ResponseWriter, r *http.Request) {}"},
		{File: "Makefile", StartLine: 5, EndLine: 8, Score: 0.55, Content: "build:\n\tgo build -o bin/app ."},
		// These should appear as refs only (no content)
		{File: "src/config.go", StartLine: 1, EndLine: 10, Score: 0.48, Content: "var defaultConfig = ..."},
		{File: "src/db.go", StartLine: 20, EndLine: 35, Score: 0.35, Content: "func Connect() {}"},
		// Below 0.3 threshold — should be excluded
		{File: "README.md", StartLine: 1, EndLine: 5, Score: 0.25, Content: "# My App"},
	}

	var sb strings.Builder
	fullCount := 5
	if fullCount > len(results) {
		fullCount = len(results)
	}
	for i := 0; i < fullCount; i++ {
		r := results[i]
		ext := ""
		if j := strings.LastIndex(r.File, "."); j >= 0 {
			ext = r.File[j+1:]
		}
		fmt.Fprintf(&sb, "### %s (lines %d-%d, score: %.2f)\n```%s\n%s\n```\n\n", r.File, r.StartLine, r.EndLine, r.Score, ext, r.Content)
	}
	var refs []string
	for i := fullCount; i < len(results); i++ {
		r := results[i]
		if r.Score < 0.3 {
			break
		}
		refs = append(refs, fmt.Sprintf("- %s (lines %d-%d, score: %.2f)", r.File, r.StartLine, r.EndLine, r.Score))
	}
	if len(refs) > 0 {
		sb.WriteString("### Also relevant\n")
		sb.WriteString(strings.Join(refs, "\n"))
		sb.WriteString("\n")
	}
	got := sb.String()

	// Top 5 should have full content
	for _, exp := range []string{
		"### src/auth.go (lines 10-25, score: 0.85)\n```go\n",
		"func Login(user, pass string)",
		"### Makefile (lines 5-8, score: 0.55)\n```\n",
	} {
		if !strings.Contains(got, exp) {
			t.Errorf("missing full result: %q", exp)
		}
	}

	// Refs section should list files without content
	if !strings.Contains(got, "### Also relevant") {
		t.Error("missing 'Also relevant' section")
	}
	if !strings.Contains(got, "- src/config.go (lines 1-10, score: 0.48)") {
		t.Error("missing config.go ref")
	}
	if !strings.Contains(got, "- src/db.go (lines 20-35, score: 0.35)") {
		t.Error("missing db.go ref")
	}

	// Below threshold should be excluded
	if strings.Contains(got, "README.md") {
		t.Error("README.md should be excluded (score < 0.3)")
	}

	// Refs should NOT contain code
	if strings.Contains(got, "var defaultConfig") {
		t.Error("refs should not contain code content")
	}

	t.Logf("Formatted output:\n%s", got)
}

func startFakeNeovim(t *testing.T, handler func(req map[string]any) any) string {
	t.Helper()
	sock := "/tmp/lg-test-" + fmt.Sprintf("%d", os.Getpid()) + ".sock"
	os.Remove(sock)
	l, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close(); os.Remove(sock) })
	go func() {
		for {
			conn, err := l.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				buf := make([]byte, 4096)
				n, _ := c.Read(buf)
				var req map[string]any
				json.Unmarshal(buf[:n], &req)
				resp := handler(req)
				data, _ := json.Marshal(resp)
				c.Write(append(data, '\n'))
			}(conn)
		}
	}()
	return sock
}

func TestReadBuffer(t *testing.T) {
	sock := startFakeNeovim(t, func(req map[string]any) any {
		if req["method"] == "read_buffer" {
			return map[string]any{
				"content":     "line one\nline two\nline three",
				"start_line":  1,
				"end_line":    3,
				"total_lines": 3,
			}
		}
		return map[string]any{"error": "unknown"}
	})
	nvim.SockPath = sock

	args, _ := json.Marshal(map[string]any{
		"name":      "read_buffer",
		"arguments": map[string]any{"path": "/tmp/test.go"},
	})
	result, err := handleToolCall(args)
	if err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(result)
	if !strings.Contains(string(data), "line one\\nline two\\nline three") {
		t.Errorf("unexpected result: %s", data)
	}
}

func TestReadBufferWithRange(t *testing.T) {
	sock := startFakeNeovim(t, func(req map[string]any) any {
		if req["method"] == "read_buffer" {
			start := int(req["start_line"].(float64))
			end := int(req["end_line"].(float64))
			if start != 2 || end != 3 {
				return map[string]any{"error": fmt.Sprintf("unexpected range %d-%d", start, end)}
			}
			return map[string]any{
				"content":     "line two\nline three",
				"start_line":  2,
				"end_line":    3,
				"total_lines": 5,
			}
		}
		return map[string]any{"error": "unknown"}
	})
	nvim.SockPath = sock

	args, _ := json.Marshal(map[string]any{
		"name":      "read_buffer",
		"arguments": map[string]any{"path": "/tmp/test.go", "start_line": 2, "end_line": 3},
	})
	result, err := handleToolCall(args)
	if err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(result)
	if !strings.Contains(string(data), "line two\\nline three") {
		t.Errorf("unexpected result: %s", data)
	}
}

func TestReadBufferNotLoaded(t *testing.T) {
	sock := startFakeNeovim(t, func(req map[string]any) any {
		// Simulates fallback: Lua reads from disk and returns content
		return map[string]any{
			"content":     "disk content",
			"start_line":  1,
			"end_line":    1,
			"total_lines": 1,
		}
	})
	nvim.SockPath = sock

	args, _ := json.Marshal(map[string]any{
		"name":      "read_buffer",
		"arguments": map[string]any{"path": "/tmp/test.go"},
	})
	result, err := handleToolCall(args)
	if err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(result)
	if !strings.Contains(string(data), "disk content") {
		t.Errorf("expected disk fallback content, got: %s", data)
	}
}

func TestReadBufferFileNotFound(t *testing.T) {
	sock := startFakeNeovim(t, func(req map[string]any) any {
		return map[string]any{"error": "file not found: /tmp/nope.go"}
	})
	nvim.SockPath = sock

	args, _ := json.Marshal(map[string]any{
		"name":      "read_buffer",
		"arguments": map[string]any{"path": "/tmp/nope.go"},
	})
	result, err := handleToolCall(args)
	if err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(result)
	if !strings.Contains(string(data), "isError") || !strings.Contains(string(data), "file not found") {
		t.Errorf("expected error result, got: %s", data)
	}
}
