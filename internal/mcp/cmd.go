// Package mcp implements the unified `lg mcp` stdio MCP server.
//
// Tool groups are selectable via --tools=core,hint,git (default: all).
package mcp

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"

	"lg/internal/mcp/core"
	"lg/internal/mcp/git"
	"lg/internal/mcp/hint"
	"lg/internal/mcp/nvim"
	"lg/internal/mcp/protocol"
)

// Server serves MCP requests for a configured set of tool groups.
type Server struct {
	groups map[string]bool
}

// ParseTools parses a comma-separated --tools value into a group set.
// Supported groups: core, hint, git, all.
func ParseTools(spec string) (map[string]bool, error) {
	groups := map[string]bool{}
	for _, part := range strings.Split(spec, ",") {
		name := strings.TrimSpace(part)
		if name == "" {
			continue
		}
		switch name {
		case "all":
			groups["core"] = true
			groups["hint"] = true
			groups["git"] = true
		case "core", "hint", "git":
			groups[name] = true
		default:
			return nil, fmt.Errorf("unknown tool group %q (expected core, hint, git, or all)", name)
		}
	}
	if len(groups) == 0 {
		return nil, fmt.Errorf("no tool groups selected")
	}
	return groups, nil
}

// NewServer creates an MCP server exposing the given tool groups.
func NewServer(groups map[string]bool) *Server {
	return &Server{groups: groups}
}

// ToolsList returns the tools/list response for enabled groups.
func (s *Server) ToolsList() any {
	var tools []protocol.ToolDef
	if s.groups["core"] {
		tools = append(tools, core.Defs()...)
	}
	if s.groups["hint"] {
		tools = append(tools, hint.Defs()...)
	}
	if s.groups["git"] {
		tools = append(tools, git.Defs()...)
	}
	return struct {
		Tools []protocol.ToolDef `json:"tools"`
	}{Tools: tools}
}

// CallTool dispatches a tools/call payload across enabled groups.
func (s *Server) CallTool(params json.RawMessage) (any, *protocol.MCPError) {
	var call struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	}
	if err := json.Unmarshal(params, &call); err != nil {
		return nil, &protocol.MCPError{Code: -32602, Message: "invalid params: " + err.Error()}
	}

	if s.groups["core"] {
		if res, handled, err := core.Call(call.Name, call.Arguments); handled {
			if err != nil {
				return nil, &protocol.MCPError{Code: -32603, Message: err.Error()}
			}
			return res, nil
		}
	}
	if s.groups["hint"] {
		if res, handled, err := hint.Call(call.Name, call.Arguments); handled {
			if err != nil {
				return nil, &protocol.MCPError{Code: -32603, Message: err.Error()}
			}
			return res, nil
		}
	}
	if s.groups["git"] {
		if res, handled, err := git.Call(call.Name, call.Arguments); handled {
			if err != nil {
				return nil, &protocol.MCPError{Code: -32603, Message: err.Error()}
			}
			return res, nil
		}
	}

	return nil, &protocol.MCPError{Code: -32601, Message: "unknown tool: " + call.Name}
}

// Run executes the `lg mcp` subcommand.
func Run(args []string) {
	fs := flag.NewFlagSet("mcp", flag.ExitOnError)
	toolsSpec := fs.String("tools", "core,hint,git", "Comma-separated tool groups to expose (core,hint,git,all)")
	_ = fs.Parse(args)

	groups, err := ParseTools(*toolsSpec)
	if err != nil {
		fmt.Fprintf(os.Stderr, "lg mcp: %v\n", err)
		os.Exit(2)
	}

	nvim.SockPath = os.Getenv("LG_SOCK")
	if nvim.SockPath == "" {
		nvim.SockPath = "/dev/shm/lg.sock"
	}
	nvim.SessionID = os.Getenv("LG_SESSION")

	srv := NewServer(groups)
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

		var req protocol.JSONRPCRequest
		if err := json.Unmarshal([]byte(line), &req); err != nil {
			continue
		}

		var resp protocol.JSONRPCResponse
		resp.JSONRPC = "2.0"
		resp.ID = req.ID

		switch req.Method {
		case "initialize":
			resp.Result = map[string]any{
				"protocolVersion": "2024-11-05",
				"capabilities":    map[string]any{"tools": map[string]any{}},
				"serverInfo":      map[string]any{"name": "lg-mcp", "version": "0.3.0"},
			}
		case "notifications/initialized":
			continue
		case "tools/list":
			resp.Result = srv.ToolsList()
		case "tools/call":
			result, rpcErr := srv.CallTool(req.Params)
			if rpcErr != nil {
				resp.Error = *rpcErr
			} else {
				resp.Result = result
			}
		default:
			// JSON-RPC notifications have no id and must never receive a response.
			if req.ID == nil {
				continue
			}
			resp.Error = protocol.MCPError{Code: -32601, Message: "method not found: " + req.Method}
		}

		out, _ := json.Marshal(resp)
		fmt.Println(string(out))
	}
}
