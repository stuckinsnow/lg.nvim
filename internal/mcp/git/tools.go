// Package git implements the read-only git MCP tools (git_log, git_show, git_diff, git_blame).
package git

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"

	"lg/internal/mcp/protocol"
)

func runGit(args ...string) (string, error) {
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

// Call handles a git tool invocation. handled is false when name is not a git tool.
func Call(name string, rawArgs json.RawMessage) (any, bool, error) {
	switch name {
	case "git_log", "git_show", "git_diff", "git_blame":
	default:
		return nil, false, nil
	}

	var args struct {
		Ref     string `json:"ref"`
		Path    string `json:"path"`
		N       int    `json:"n"`
		Unified int    `json:"unified"`
	}
	if err := json.Unmarshal(rawArgs, &args); err != nil {
		return nil, true, err
	}

	var out string
	var err error

	switch name {
	case "git_log":
		n := args.N
		if n == 0 {
			n = 20
		}
		cmdArgs := []string{"log", fmt.Sprintf("-n%d", n), "--oneline", "--no-decorate"}
		if args.Path != "" {
			cmdArgs = append(cmdArgs, "--", args.Path)
		}
		out, err = runGit(cmdArgs...)

	case "git_show":
		ref := args.Ref
		if ref == "" {
			ref = "HEAD"
		}
		if args.Path != "" {
			out, err = runGit("show", ref, "--", args.Path)
		} else {
			out, err = runGit("show", ref)
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
		out, err = runGit(cmdArgs...)

	case "git_blame":
		if args.Path == "" {
			return protocol.ToolResult{Content: []protocol.TextContent{{Type: "text", Text: "path is required"}}, IsError: true}, true, nil
		}
		out, err = runGit("blame", args.Path)
	}

	if err != nil {
		return protocol.ToolResult{Content: []protocol.TextContent{{Type: "text", Text: err.Error()}}, IsError: true}, true, nil
	}
	return protocol.ToolResult{Content: []protocol.TextContent{{Type: "text", Text: out}}}, true, nil
}

// Defs returns the MCP tool definitions for the git group.
func Defs() []protocol.ToolDef {
	f := false
	return []protocol.ToolDef{
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
	}
}
