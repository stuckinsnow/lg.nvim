package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"lg-git-mcp/internal/git"
	"lg-git-mcp/internal/protocol"
	"os"
	"strings"
)

func main() {
	reader := bufio.NewReader(os.Stdin)
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			break
		}
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}

		var req protocol.Request
		if err := json.Unmarshal([]byte(line), &req); err != nil {
			continue
		}

		var resp protocol.Response
		resp.JSONRPC = "2.0"
		resp.ID = req.ID

		switch req.Method {
		case "initialize":
			resp.Result = map[string]any{
				"protocolVersion": "2024-11-05",
				"capabilities":    map[string]any{"tools": map[string]any{}},
				"serverInfo":      map[string]any{"name": "lg-git-mcp", "version": "0.1.0"},
			}
		case "notifications/initialized":
			continue
		case "tools/list":
			resp.Result = git.HandleToolsList()
		case "tools/call":
			result, callErr := git.HandleToolCall(req.Params)
			if callErr != nil {
				resp.Error = map[string]any{"code": -32603, "message": callErr.Error()}
			} else {
				resp.Result = result
			}
		default:
			resp.Error = map[string]any{"code": -32601, "message": "method not found: " + req.Method}
		}

		out, _ := json.Marshal(resp)
		fmt.Println(string(out))
	}
}
