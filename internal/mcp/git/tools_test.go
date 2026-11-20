package git

import (
	"encoding/json"
	"strings"
	"testing"

	"lg/internal/mcp/protocol"
)

func TestGitLog(t *testing.T) {
	resp := callTool(t, "git_log", `{"n": 5}`)
	if resp.IsError {
		t.Fatal(resp.Content[0].Text)
	}
	lines := strings.Split(strings.TrimSpace(resp.Content[0].Text), "\n")
	if len(lines) == 0 || len(lines) > 5 {
		t.Fatalf("expected 1-5 lines, got %d", len(lines))
	}
}

func TestGitShow(t *testing.T) {
	resp := callTool(t, "git_show", `{"ref": "HEAD"}`)
	if resp.IsError {
		t.Fatal(resp.Content[0].Text)
	}
	if !strings.Contains(resp.Content[0].Text, "commit") && !strings.Contains(resp.Content[0].Text, "diff") {
		t.Fatal("expected commit info in output")
	}
}

func TestGitDiff(t *testing.T) {
	resp := callTool(t, "git_diff", `{}`)
	if resp.IsError {
		t.Fatal(resp.Content[0].Text)
	}
}

func TestGitBlame(t *testing.T) {
	resp := callTool(t, "git_blame", `{"path": "README.md"}`)
	if resp.IsError {
		t.Fatal(resp.Content[0].Text)
	}
	if resp.Content[0].Text == "" {
		t.Fatal("expected blame output")
	}
}

func TestGitBlameNoPath(t *testing.T) {
	resp := callTool(t, "git_blame", `{}`)
	if !resp.IsError {
		t.Fatal("expected error for missing path")
	}
}

func TestUnknownTool(t *testing.T) {
	_, handled, err := Call("nope", json.RawMessage(`{}`))
	if handled || err != nil {
		t.Fatalf("expected handled=false, err=nil for unknown tool, got handled=%v err=%v", handled, err)
	}
}

func callTool(t *testing.T, name, args string) protocol.ToolResult {
	t.Helper()
	result, handled, err := Call(name, json.RawMessage(args))
	if err != nil {
		t.Fatal(err)
	}
	if !handled {
		t.Fatalf("tool %q not handled", name)
	}
	return result.(protocol.ToolResult)
}
