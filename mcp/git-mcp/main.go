package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

type jsonRPCRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      any             `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type jsonRPCResponse struct {
	JSONRPC string `json:"jsonrpc"`
	ID      any    `json:"id"`
	Result  any    `json:"result,omitempty"`
	Error   any    `json:"error,omitempty"`
}

type textContent struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

type toolResult struct {
	Content []textContent `json:"content"`
	IsError bool          `json:"isError,omitempty"`
}

type toolSchema struct {
	Type                 string         `json:"type"`
	Properties           map[string]any `json:"properties"`
	Required             []string       `json:"required"`
	AdditionalProperties *bool          `json:"additionalProperties,omitempty"`
}

type toolDef struct {
	Name        string     `json:"name"`
	Description string     `json:"description"`
	InputSchema toolSchema `json:"inputSchema"`
}

func git(args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	if top, err := exec.Command("git", "rev-parse", "--show-toplevel").Output(); err == nil {
		cmd.Dir = strings.TrimSpace(string(top))
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("%s: %s", err, string(out))
	}
	return string(out), nil
}

func handleToolCall(params json.RawMessage) (any, error) {
	var call struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	}
	if err := json.Unmarshal(params, &call); err != nil {
		return nil, err
	}

	var args struct {
		Ref     string `json:"ref"`
		Path    string `json:"path"`
		N       int    `json:"n"`
		Unified int    `json:"unified"`
	}
	json.Unmarshal(call.Arguments, &args)

	var out string
	var err error

	switch call.Name {
	case "git_log":
		n := args.N
		if n == 0 {
			n = 20
		}
		cmdArgs := []string{"log", fmt.Sprintf("-n%d", n), "--oneline", "--no-decorate"}
		if args.Path != "" {
			cmdArgs = append(cmdArgs, "--", args.Path)
		}
		out, err = git(cmdArgs...)

	case "git_show":
		ref := args.Ref
		if ref == "" {
			ref = "HEAD"
		}
		if args.Path != "" {
			out, err = git("show", ref+"--", args.Path)
		} else {
			out, err = git("show", ref)
		}

	case "git_diff":
		cmdArgs := []string{"diff"}
		if args.Ref != "" {
			cmdArgs = append(cmdArgs, args.Ref)
		}
		if args.Unified > 0 {
			cmdArgs = append(cmdArgs, fmt.Sprintf("-U%d", args.Unified))
		}
		if args.Path != "" {
			cmdArgs = append(cmdArgs, "--", args.Path)
		}
		out, err = git(cmdArgs...)

	case "git_blame":
		if args.Path == "" {
			return toolResult{Content: []textContent{{Type: "text", Text: "path is required"}}, IsError: true}, nil
		}
		out, err = git("blame", args.Path)

	default:
		return nil, fmt.Errorf("unknown tool: %s", call.Name)
	}

	if err != nil {
		return toolResult{Content: []textContent{{Type: "text", Text: err.Error()}}, IsError: true}, nil
	}
	return toolResult{Content: []textContent{{Type: "text", Text: out}}}, nil
}

func handleToolsList() any {
	f := false
	return struct {
		Tools []toolDef `json:"tools"`
	}{
		Tools: []toolDef{
			{
				Name:        "git_log",
				Description: "Show git commit log. Returns oneline format.",
				InputSchema: toolSchema{
					Type: "object",
					Properties: map[string]any{
						"n":    map[string]any{"type": "integer", "description": "Number of commits (default 20)"},
						"path": map[string]any{"type": "string", "description": "Optional file path to filter"},
					},
					Required: []string{}, AdditionalProperties: &f,
				},
			},
			{
				Name:        "git_show",
				Description: "Show a commit's full diff and message.",
				InputSchema: toolSchema{
					Type: "object",
					Properties: map[string]any{
						"ref":  map[string]any{"type": "string", "description": "Commit ref (default HEAD)"},
						"path": map[string]any{"type": "string", "description": "Optional file path"},
					},
					Required: []string{}, AdditionalProperties: &f,
				},
			},
			{
				Name:        "git_diff",
				Description: "Show git diff. No ref = working tree vs index. Use ref like HEAD~1..HEAD for between commits.",
				InputSchema: toolSchema{
					Type: "object",
					Properties: map[string]any{
						"ref":     map[string]any{"type": "string", "description": "Diff ref (e.g. HEAD~1, HEAD~3..HEAD)"},
						"path":    map[string]any{"type": "string", "description": "Optional file path"},
						"unified": map[string]any{"type": "integer", "description": "Context lines (default 3)"},
					},
					Required: []string{}, AdditionalProperties: &f,
				},
			},
			{
				Name:        "git_blame",
				Description: "Show git blame for a file.",
				InputSchema: toolSchema{
					Type: "object",
					Properties: map[string]any{
						"path": map[string]any{"type": "string", "description": "File path to blame"},
					},
					Required: []string{"path"}, AdditionalProperties: &f,
				},
			},
		},
	}
}

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

		var req jsonRPCRequest
		if err := json.Unmarshal([]byte(line), &req); err != nil {
			continue
		}

		var resp jsonRPCResponse
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
			resp.Result = handleToolsList()
		case "tools/call":
			result, callErr := handleToolCall(req.Params)
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
