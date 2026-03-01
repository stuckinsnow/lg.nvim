package main

import (
	"encoding/json"

	"lg-git-mcp/internal/git"
	"lg-git-mcp/internal/protocol"
	"strings"
	"testing"
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
	// Working tree diff may be empty, that's fine
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
	_, err := git.HandleToolCall(json.RawMessage(`{"name": "nope", "arguments": {}}`))
	if err == nil {
		t.Fatal("expected error for unknown tool")
	}
}

func callTool(t *testing.T, name, args string) protocol.ToolResult {
	t.Helper()
	params := json.RawMessage(`{"name": "` + name + `", "arguments": ` + args + `}`)
	result, err := git.HandleToolCall(params)
	if err != nil {
		t.Fatal(err)
	}
	return result.(protocol.ToolResult)
}
