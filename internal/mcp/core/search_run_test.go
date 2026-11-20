package core

import (
	"encoding/json"
	"lg/internal/mcp/nvim"
	"lg/internal/mcp/protocol"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestResolveInCWD(t *testing.T) {
	cwd := "/workspace/proj"
	if got, err := resolveInCWD(cwd, ""); err != nil || got != cwd {
		t.Fatalf("empty rel: got (%q, %v)", got, err)
	}
	if got, err := resolveInCWD(cwd, "cmd/app"); err != nil || got != "/workspace/proj/cmd/app" {
		t.Fatalf("rel path: got (%q, %v)", got, err)
	}
	if _, err := resolveInCWD(cwd, "../other"); err == nil {
		t.Fatal("expected error for escaping relative path")
	}
	if _, err := resolveInCWD(cwd, "/etc/passwd"); err == nil {
		t.Fatal("expected error for absolute path outside cwd")
	}
}

func TestHandleGrepAndGlob(t *testing.T) {
	dir := t.TempDir()
	sub := filepath.Join(dir, "pkg")
	if err := os.MkdirAll(sub, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sub, "hello.go"), []byte("package pkg\nfunc HelloWorld() {}\n"), 0644); err != nil {
		t.Fatal(err)
	}

	orig, _ := os.Getwd()
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(orig) })

	// Grep hit
	res := handleGrep(json.RawMessage(`{"pattern":"HelloWorld"}`))
	if res.IsError || len(res.Content) == 0 || !strings.Contains(res.Content[0].Text, "pkg/hello.go:2:") {
		t.Fatalf("unexpected grep result: %+v", res)
	}

	// Grep miss (not an error)
	res = handleGrep(json.RawMessage(`{"pattern":"DoesNotExistXYZ"}`))
	if res.IsError || !strings.Contains(res.Content[0].Text, "No matches") {
		t.Fatalf("unexpected grep miss result: %+v", res)
	}

	// Grep escape rejected
	res = handleGrep(json.RawMessage(`{"pattern":"root","path":".."}`))
	if !res.IsError {
		t.Fatalf("expected error for path escape, got: %+v", res)
	}

	// Glob hit
	res = handleGlob(json.RawMessage(`{"pattern":"*.go"}`))
	if res.IsError || !strings.Contains(res.Content[0].Text, "pkg/hello.go") {
		t.Fatalf("unexpected glob result: %+v", res)
	}

	// Glob miss
	res = handleGlob(json.RawMessage(`{"pattern":"*.rs"}`))
	if res.IsError || !strings.Contains(res.Content[0].Text, "No files matched") {
		t.Fatalf("unexpected glob miss result: %+v", res)
	}
}

func TestHandleRunApproval(t *testing.T) {
	sock := startFakeNeovim(t, func(req map[string]any) any {
		if req["method"] != "run_command" {
			return map[string]any{"ok": false, "error": "unexpected method"}
		}
		switch req["command"] {
		case "echo hi-lg":
			return map[string]any{"ok": true, "exit_code": 0, "output": "hi-lg"}
		case "false":
			return map[string]any{"ok": true, "exit_code": 1, "output": "boom"}
		case "sleep 99":
			return map[string]any{"ok": true, "timed_out": true, "output": "partial"}
		default:
			return map[string]any{"ok": false, "rejected": true, "error": "Command rejected by user"}
		}
	})
	nvim.SockPath = sock

	// Approved success
	args, _ := json.Marshal(map[string]any{
		"name":      "lg_run",
		"arguments": map[string]any{"command": "echo hi-lg"},
	})
	raw, err := handleToolCall(args)
	if err != nil {
		t.Fatal(err)
	}
	res := raw.(protocol.ToolResult)
	if res.IsError || res.Content[0].Text != "hi-lg" {
		t.Fatalf("expected approved output 'hi-lg', got %+v", res)
	}

	// Non-zero exit code
	args, _ = json.Marshal(map[string]any{
		"name":      "lg_run",
		"arguments": map[string]any{"command": "false"},
	})
	raw, err = handleToolCall(args)
	if err != nil {
		t.Fatal(err)
	}
	res = raw.(protocol.ToolResult)
	if !res.IsError || !strings.Contains(res.Content[0].Text, "exit code 1") || !strings.Contains(res.Content[0].Text, "boom") {
		t.Fatalf("expected exit code 1 with output, got %+v", res)
	}

	// Timed out
	args, _ = json.Marshal(map[string]any{
		"name":      "lg_run",
		"arguments": map[string]any{"command": "sleep 99", "timeout_seconds": 5},
	})
	raw, err = handleToolCall(args)
	if err != nil {
		t.Fatal(err)
	}
	res = raw.(protocol.ToolResult)
	if !res.IsError || !strings.Contains(res.Content[0].Text, "timed out after 5s") {
		t.Fatalf("expected timeout error, got %+v", res)
	}

	// Rejected
	args, _ = json.Marshal(map[string]any{
		"name":      "lg_run",
		"arguments": map[string]any{"command": "rm -rf /"},
	})
	raw, err = handleToolCall(args)
	if err != nil {
		t.Fatal(err)
	}
	res = raw.(protocol.ToolResult)
	if !res.IsError || !strings.Contains(res.Content[0].Text, "Do NOT retry") {
		t.Fatalf("expected rejection error, got %+v", res)
	}
}
