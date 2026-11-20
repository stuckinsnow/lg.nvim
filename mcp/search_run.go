package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"lg-mcp/internal/nvim"
	"lg-mcp/internal/protocol"
)

const (
	defaultMaxGrepLines = 100
	defaultMaxGlobFiles = 200
	maxSearchLimit      = 500
	defaultRunTimeout   = 60
	maxRunTimeout       = 300
	maxRunOutputBytes   = 32 * 1024
)

// resolveInCWD resolves rel against cwd and ensures the result stays inside cwd.
func resolveInCWD(cwd, rel string) (string, error) {
	if rel == "" || rel == "." {
		return cwd, nil
	}
	target := rel
	if !filepath.IsAbs(target) {
		target = filepath.Join(cwd, target)
	}
	target = filepath.Clean(target)
	r, err := filepath.Rel(cwd, target)
	if err != nil || r == ".." || strings.HasPrefix(r, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("path escapes workspace: %s", rel)
	}
	return target, nil
}

func truncateLines(s string, maxLines int) (string, bool) {
	s = strings.TrimRight(s, "\n")
	if s == "" {
		return "", false
	}
	lines := strings.Split(s, "\n")
	if len(lines) <= maxLines {
		return s, false
	}
	return strings.Join(lines[:maxLines], "\n"), true
}

func handleGrep(raw json.RawMessage) protocol.ToolResult {
	var args struct {
		Pattern    string `json:"pattern"`
		Path       string `json:"path"`
		Glob       string `json:"glob"`
		IgnoreCase bool   `json:"ignore_case"`
		MaxResults int    `json:"max_results"`
	}
	if err := json.Unmarshal(raw, &args); err != nil {
		return toolErr("invalid arguments: " + err.Error())
	}
	if args.Pattern == "" {
		return toolErr("pattern is required")
	}

	cwd, err := os.Getwd()
	if err != nil {
		return toolErr("getwd failed: " + err.Error())
	}
	target, err := resolveInCWD(cwd, args.Path)
	if err != nil {
		return toolErr(err.Error())
	}

	limit := args.MaxResults
	if limit <= 0 {
		limit = defaultMaxGrepLines
	}
	if limit > maxSearchLimit {
		limit = maxSearchLimit
	}

	rgArgs := []string{"--no-heading", "--line-number", "--color=never", "--max-filesize=1M"}
	if args.IgnoreCase {
		rgArgs = append(rgArgs, "-i")
	}
	if args.Glob != "" {
		rgArgs = append(rgArgs, "-g", args.Glob)
	}
	rgArgs = append(rgArgs, "--", args.Pattern, target)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "rg", rgArgs...)
	cmd.Dir = cwd
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) && exitErr.ExitCode() == 1 {
			return protocol.ToolResult{
				Content: []protocol.TextContent{{Type: "text", Text: "No matches found."}},
			}
		}
		if errors.Is(err, exec.ErrNotFound) {
			return toolErr("rg (ripgrep) not found in PATH")
		}
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return toolErr("grep failed: " + msg)
	}

	// Trim absolute cwd prefix so output shows clean relative paths.
	out := strings.ReplaceAll(stdout.String(), strings.TrimRight(cwd, "/")+"/", "")
	trimmed, truncated := truncateLines(out, limit)
	if truncated {
		trimmed += fmt.Sprintf("\n... (truncated at %d lines)", limit)
	}
	return protocol.ToolResult{
		Content: []protocol.TextContent{{Type: "text", Text: trimmed}},
	}
}

func handleGlob(raw json.RawMessage) protocol.ToolResult {
	var args struct {
		Pattern    string `json:"pattern"`
		Path       string `json:"path"`
		MaxResults int    `json:"max_results"`
	}
	if err := json.Unmarshal(raw, &args); err != nil {
		return toolErr("invalid arguments: " + err.Error())
	}
	if args.Pattern == "" {
		return toolErr("pattern is required")
	}

	cwd, err := os.Getwd()
	if err != nil {
		return toolErr("getwd failed: " + err.Error())
	}
	target, err := resolveInCWD(cwd, args.Path)
	if err != nil {
		return toolErr(err.Error())
	}

	limit := args.MaxResults
	if limit <= 0 {
		limit = defaultMaxGlobFiles
	}
	if limit > maxSearchLimit {
		limit = maxSearchLimit
	}

	rgArgs := []string{"--files", "--color=never", "-g", args.Pattern, target}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "rg", rgArgs...)
	cmd.Dir = cwd
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) && exitErr.ExitCode() == 1 {
			return protocol.ToolResult{
				Content: []protocol.TextContent{{Type: "text", Text: "No files matched."}},
			}
		}
		if errors.Is(err, exec.ErrNotFound) {
			return toolErr("rg (ripgrep) not found in PATH")
		}
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return toolErr("glob failed: " + msg)
	}

	out := strings.ReplaceAll(stdout.String(), strings.TrimRight(cwd, "/")+"/", "")
	trimmed, truncated := truncateLines(out, limit)
	if truncated {
		trimmed += fmt.Sprintf("\n... (truncated at %d files)", limit)
	}
	return protocol.ToolResult{
		Content: []protocol.TextContent{{Type: "text", Text: trimmed}},
	}
}

func handleRun(raw json.RawMessage) protocol.ToolResult {
	var args struct {
		Command        string `json:"command"`
		TimeoutSeconds int    `json:"timeout_seconds"`
	}
	if err := json.Unmarshal(raw, &args); err != nil {
		return toolErr("invalid arguments: " + err.Error())
	}
	if strings.TrimSpace(args.Command) == "" {
		return toolErr("command is required")
	}

	timeout := args.TimeoutSeconds
	if timeout <= 0 {
		timeout = defaultRunTimeout
	}
	if timeout > maxRunTimeout {
		timeout = maxRunTimeout
	}

	// Neovim prompts for approval and runs the command in a visible terminal
	// split so the user and agent see the exact same output.
	resp, err := nvim.SendToNeovim(map[string]any{
		"method":          "run_command",
		"command":         args.Command,
		"timeout_seconds": timeout,
	})
	if err != nil {
		return toolErr("run failed: " + err.Error())
	}
	var res struct {
		OK       bool   `json:"ok"`
		Rejected bool   `json:"rejected"`
		TimedOut bool   `json:"timed_out"`
		ExitCode int    `json:"exit_code"`
		Output   string `json:"output"`
		Error    string `json:"error"`
	}
	if err := json.Unmarshal(resp, &res); err != nil {
		return toolErr("invalid run response: " + string(resp))
	}
	if res.Rejected {
		msg := res.Error
		if msg == "" {
			msg = "Command rejected by user"
		}
		return toolErr(msg + ". Do NOT retry this command.")
	}
	if !res.OK {
		msg := res.Error
		if msg == "" {
			msg = "command failed"
		}
		return toolErr(msg)
	}

	text := res.Output
	if len(text) > maxRunOutputBytes {
		text = text[:maxRunOutputBytes] + "\n... (output truncated)"
	}
	if res.TimedOut {
		return toolErr(fmt.Sprintf("command timed out after %ds\n%s", timeout, text))
	}
	if res.ExitCode != 0 {
		if text == "" {
			text = fmt.Sprintf("exit code %d", res.ExitCode)
		} else {
			text = fmt.Sprintf("exit code %d\n%s", res.ExitCode, text)
		}
		return protocol.ToolResult{
			Content: []protocol.TextContent{{Type: "text", Text: text}},
			IsError: true,
		}
	}
	if text == "" {
		text = "(no output)"
	}
	return protocol.ToolResult{
		Content: []protocol.TextContent{{Type: "text", Text: text}},
	}
}

func grepToolDef() protocol.ToolDef {
	f := false
	return protocol.ToolDef{
		Name:        "lg_grep",
		Description: "Search files in the workspace using ripgrep (read-only). Respects .gitignore.",
		InputSchema: protocol.ToolSchema{
			Type: "object",
			Properties: map[string]any{
				"pattern":     map[string]string{"type": "string", "description": "Regex pattern to search for"},
				"path":        map[string]string{"type": "string", "description": "Optional directory or file path within the workspace (defaults to workspace root)"},
				"glob":        map[string]string{"type": "string", "description": "Optional glob filter (e.g. '*.go', '!vendor/**')"},
				"ignore_case": map[string]any{"type": "boolean", "description": "Case-insensitive search"},
				"max_results": map[string]any{"type": "integer", "description": "Max matching lines to return (default 100, max 500)"},
			},
			Required:             []string{"pattern"},
			AdditionalProperties: &f,
		},
	}
}

func globToolDef() protocol.ToolDef {
	f := false
	return protocol.ToolDef{
		Name:        "lg_glob",
		Description: "Find files in the workspace matching a glob pattern (read-only). Respects .gitignore.",
		InputSchema: protocol.ToolSchema{
			Type: "object",
			Properties: map[string]any{
				"pattern":     map[string]string{"type": "string", "description": "Glob pattern (e.g. '**/*.go', 'cmd/*')"},
				"path":        map[string]string{"type": "string", "description": "Optional directory within the workspace (defaults to workspace root)"},
				"max_results": map[string]any{"type": "integer", "description": "Max files to return (default 200, max 500)"},
			},
			Required:             []string{"pattern"},
			AdditionalProperties: &f,
		},
	}
}

func runToolDef() protocol.ToolDef {
	f := false
	return protocol.ToolDef{
		Name:        "lg_run",
		Description: "Run a shell command in the workspace after explicit user approval in Neovim. If the user rejects, do NOT retry.",
		InputSchema: protocol.ToolSchema{
			Type: "object",
			Properties: map[string]any{
				"command":         map[string]string{"type": "string", "description": "Shell command to run"},
				"timeout_seconds": map[string]any{"type": "integer", "description": "Timeout in seconds (default 60, max 300)"},
			},
			Required:             []string{"command"},
			AdditionalProperties: &f,
		},
	}
}
