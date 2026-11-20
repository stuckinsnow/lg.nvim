package session

import (
	"encoding/json"
	"lg/internal/acp/protocol"
	"testing"
)

func TestSliceLines(t *testing.T) {
	content := "a\nb\nc\n"
	cases := []struct {
		line, limit int
		want        string
	}{
		{0, 0, content},
		{1, 0, content},
		{1, 2001, content},
		{2, 0, "b\nc\n"},
		{2, 1, "b\n"},
		{9, 1, ""},
	}
	for _, c := range cases {
		if got := sliceLines(content, c.line, c.limit); got != c.want {
			t.Errorf("sliceLines(line=%d, limit=%d) = %q, want %q", c.line, c.limit, got, c.want)
		}
	}
}

func TestFormatToolCall(t *testing.T) {
	cases := []struct {
		name   string
		update protocol.SessionUpdate
		cwd    string
		want   string
	}{
		{
			name: "mcp read_buffer with path and range",
			update: protocol.SessionUpdate{
				Title:    "Run mcp_lg_read_buffer",
				RawInput: json.RawMessage(`{"path":"/repo/cmd/gitty/main.go","start_line":10,"end_line":80}`),
			},
			cwd:  "/repo",
			want: "Run mcp_lg_read_buffer cmd/gitty/main.go:10-80",
		},
		{
			name: "mcp read_buffer with path only",
			update: protocol.SessionUpdate{
				Title:    "Run mcp_lg_read_buffer",
				RawInput: json.RawMessage(`{"path":"/repo/cmd/gitty/main.go"}`),
			},
			cwd:  "/repo",
			want: "Run mcp_lg_read_buffer cmd/gitty/main.go",
		},
		{
			name: "title already contains path",
			update: protocol.SessionUpdate{
				Title:    "Read cmd/gitty/main.go",
				RawInput: json.RawMessage(`{"path":"/repo/cmd/gitty/main.go"}`),
			},
			cwd:  "/repo",
			want: "Read cmd/gitty/main.go",
		},
		{
			name: "fallback to locations",
			update: protocol.SessionUpdate{
				Title:     "Run mcp_lg_read_buffer",
				Locations: []protocol.ToolLocation{{Path: "/repo/internal/home.go", Line: 42}},
			},
			cwd:  "/repo",
			want: "Run mcp_lg_read_buffer internal/home.go:42",
		},
		{
			name: "no rawInput or locations",
			update: protocol.SessionUpdate{
				Title: "Run mcp_lg_get_diagnostics",
			},
			cwd:  "/repo",
			want: "Run mcp_lg_get_diagnostics",
		},
		{
			name: "mcp lg_run with command",
			update: protocol.SessionUpdate{
				Title:    "Run mcp_lg_lg_run",
				RawInput: json.RawMessage(`{"command":"go test ./..."}`),
			},
			cwd:  "/repo",
			want: "Run mcp_lg_run go test ./...",
		},
		{
			name: "mcp lg_grep with pattern",
			update: protocol.SessionUpdate{
				Title:    "Run mcp_lg_lg_grep",
				RawInput: json.RawMessage(`{"pattern":"activity|notification"}`),
			},
			cwd:  "/repo",
			want: "Run mcp_lg_grep activity|notification",
		},
		{
			name: "mcp lg_write_file deduplicates lg_lg_",
			update: protocol.SessionUpdate{
				Title:    "Run mcp_lg_lg_write_file",
				RawInput: json.RawMessage(`{"path":"/repo/internal/ui/model.go"}`),
			},
			cwd:  "/repo",
			want: "Run mcp_lg_write_file internal/ui/model.go",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := formatToolCall(c.update, c.cwd); got != c.want {
				t.Errorf("formatToolCall() = %q, want %q", got, c.want)
			}
		})
	}
}
