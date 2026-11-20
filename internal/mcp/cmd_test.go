package mcp

import (
	"encoding/json"
	"testing"

	"lg/internal/mcp/protocol"
)

func toolNames(t *testing.T, srv *Server) map[string]bool {
	t.Helper()
	raw, err := json.Marshal(srv.ToolsList())
	if err != nil {
		t.Fatal(err)
	}
	var res struct {
		Tools []protocol.ToolDef `json:"tools"`
	}
	if err := json.Unmarshal(raw, &res); err != nil {
		t.Fatal(err)
	}
	out := make(map[string]bool, len(res.Tools))
	for _, d := range res.Tools {
		out[d.Name] = true
	}
	return out
}

func TestParseTools(t *testing.T) {
	groups, err := ParseTools("core,hint,git")
	if err != nil {
		t.Fatal(err)
	}
	if !groups["core"] || !groups["hint"] || !groups["git"] {
		t.Fatalf("expected all groups, got %v", groups)
	}

	allGroups, err := ParseTools("all")
	if err != nil {
		t.Fatal(err)
	}
	if !allGroups["core"] || !allGroups["hint"] || !allGroups["git"] {
		t.Fatalf("expected all groups from 'all', got %v", allGroups)
	}

	if _, err := ParseTools("core,bogus"); err == nil {
		t.Fatal("expected error for unknown group")
	}
	if _, err := ParseTools(" , "); err == nil {
		t.Fatal("expected error for empty group spec")
	}
}

func TestToolsListFiltering(t *testing.T) {
	gitOnly, _ := ParseTools("git")
	names := toolNames(t, NewServer(gitOnly))
	if !names["git_log"] || !names["git_diff"] {
		t.Fatalf("expected git tools, got %v", names)
	}
	if names["paint_edit"] || names["lg_hint"] {
		t.Fatalf("unexpected non-git tools in git-only list: %v", names)
	}

	hintOnly, _ := ParseTools("hint")
	names = toolNames(t, NewServer(hintOnly))
	if !names["lg_hint"] || !names["lg_suggest"] || !names["get_hints"] {
		t.Fatalf("expected hint tools, got %v", names)
	}
	if names["git_log"] || names["read_buffer"] {
		t.Fatalf("unexpected non-hint tools in hint-only list: %v", names)
	}

	all, _ := ParseTools("core,hint,git")
	names = toolNames(t, NewServer(all))
	for _, want := range []string{"paint_edit", "lg_write_file", "lg_hint", "get_hints", "git_log", "git_blame"} {
		if !names[want] {
			t.Errorf("missing expected tool %q in full list", want)
		}
	}
}

func TestCallToolRespectsEnabledGroups(t *testing.T) {
	coreOnly, _ := ParseTools("core")
	srv := NewServer(coreOnly)

	_, rpcErr := srv.CallTool(json.RawMessage(`{"name":"git_log","arguments":{"n":1}}`))
	if rpcErr == nil || rpcErr.Code != -32601 {
		t.Fatalf("expected -32601 for disabled git_log, got %+v", rpcErr)
	}

	gitOnly, _ := ParseTools("git")
	srv = NewServer(gitOnly)
	res, rpcErr := srv.CallTool(json.RawMessage(`{"name":"git_log","arguments":{"n":1}}`))
	if rpcErr != nil {
		t.Fatalf("unexpected error calling enabled git_log: %+v", rpcErr)
	}
	tr, ok := res.(protocol.ToolResult)
	if !ok || tr.IsError {
		t.Fatalf("expected successful ToolResult, got %#v", res)
	}
}
