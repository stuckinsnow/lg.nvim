package git

import (
	"encoding/json"
	"fmt"
	"lg-git-mcp/internal/protocol"
	"os/exec"
	"strings"
)

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

func HandleToolCall(params json.RawMessage) (any, error) {
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
	if err := json.Unmarshal(call.Arguments, &args); err != nil {
		return nil, err
	}

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
			return protocol.ToolResult{Content: []protocol.TextContent{{Type: "text", Text: "path is required"}}, IsError: true}, nil
		}
		out, err = git("blame", args.Path)

	default:
		return nil, fmt.Errorf("unknown tool: %s", call.Name)
	}

	if err != nil {
		return protocol.ToolResult{Content: []protocol.TextContent{{Type: "text", Text: err.Error()}}, IsError: true}, nil
	}
	return protocol.ToolResult{Content: []protocol.TextContent{{Type: "text", Text: out}}}, nil
}

func HandleToolsList() any {
	f := false
	return struct {
		Tools []protocol.ToolDef `json:"tools"`
	}{
		Tools: []protocol.ToolDef{
			{
				Name:        "git_log",
				Description: "Show git commit log. Returns oneline format.",
				InputSchema: protocol.ToolSchema{
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
				InputSchema: protocol.ToolSchema{
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
				InputSchema: protocol.ToolSchema{
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
				InputSchema: protocol.ToolSchema{
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
