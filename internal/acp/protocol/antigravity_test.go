package protocol

import (
	"encoding/json"
	"testing"
)

func TestACPMCPServers(t *testing.T) {
	got := ACPMCPServers(map[string]any{
		"lg-hint": map[string]any{
			"command": "/bin/lg-hint-mcp",
			"args":    []any{},
			"env":     map[string]any{"LG_SOCK": "/dev/shm/lg.sock", "LG_HINT_SOCK": "/dev/shm/lg-hint.sock"},
		},
		"lg":     map[string]any{"command": "/bin/lg-mcp", "env": map[string]any{"LG_SOCK": "/dev/shm/lg.sock"}},
		"broken": map[string]any{"args": []any{"x"}},
	})
	data, _ := json.Marshal(got)
	want := `[{"args":[],"command":"/bin/lg-mcp","env":[{"name":"LG_SOCK","value":"/dev/shm/lg.sock"}],"name":"lg"},` +
		`{"args":[],"command":"/bin/lg-hint-mcp","env":[{"name":"LG_HINT_SOCK","value":"/dev/shm/lg-hint.sock"},{"name":"LG_SOCK","value":"/dev/shm/lg.sock"}],"name":"lg-hint"}]`
	if string(data) != want {
		t.Fatalf("got  %s\nwant %s", data, want)
	}
}

func TestSessionNewRequestEmptyServers(t *testing.T) {
	for _, servers := range []any{nil, map[string]any{}, []any{}} {
		msg := SessionNewRequest(1, "/tmp", servers)
		var params struct {
			MCPServers json.RawMessage `json:"mcpServers"`
		}
		json.Unmarshal(msg.Params, &params)
		if string(params.MCPServers) != "[]" {
			t.Fatalf("servers %#v: got %s, want []", servers, params.MCPServers)
		}
	}
}

func TestAuthenticateRequest(t *testing.T) {
	data, _ := json.Marshal(AuthenticateRequest(2, "oauth-personal"))
	want := `{"jsonrpc":"2.0","id":2,"method":"authenticate","params":{"methodId":"oauth-personal"}}`
	if string(data) != want {
		t.Fatalf("got %s", data)
	}
}
