package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"lg-mcp/internal/nvim"
	"lg-mcp/internal/protocol"
	"lg-mcp/internal/search"
	"os"
	"strings"
)

func handleToolCall(params json.RawMessage) (any, error) {
	var call struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	}
	if err := json.Unmarshal(params, &call); err != nil {
		return nil, err
	}

	switch call.Name {
	case "paint_edit":
		var args struct {
			Edits     []protocol.NvimEdit `json:"edits"`
			EditToken string              `json:"edit_token"`
		}
		if err := json.Unmarshal(call.Arguments, &args); err != nil {
			return protocol.ToolResult{
				Content: []protocol.TextContent{{Type: "text", Text: "invalid arguments: " + err.Error()}},
				IsError: true,
			}, nil
		}
		if err := nvim.ApplyEdits(args.Edits, args.EditToken); err != nil {
			return protocol.ToolResult{
				Content: []protocol.TextContent{{Type: "text", Text: "edit failed: " + err.Error()}},
				IsError: true,
			}, nil
		}
		return protocol.ToolResult{
			Content: []protocol.TextContent{{Type: "text", Text: fmt.Sprintf("%d region(s) updated", len(args.Edits))}},
		}, nil

	case "get_painted_regions":
		var args struct {
			EditToken string `json:"edit_token"`
		}
		if err := json.Unmarshal(call.Arguments, &args); err != nil {
			return nil, err
		}
		regions, err := nvim.GetRegions(args.EditToken)
		if err != nil {
			return protocol.ToolResult{
				Content: []protocol.TextContent{{Type: "text", Text: "failed to get regions: " + err.Error()}},
				IsError: true,
			}, nil
		}
		data, _ := json.MarshalIndent(regions, "", "  ")
		return protocol.ToolResult{
			Content: []protocol.TextContent{{Type: "text", Text: string(data)}},
		}, nil

	case "lg_search_codebase":
		if search.IndexURL == "" {
			return protocol.ToolResult{
				Content: []protocol.TextContent{{Type: "text", Text: "LG_INDEX_URL not set"}},
				IsError: true,
			}, nil
		}
		var args struct {
			Query string `json:"query"`
			TopN  int    `json:"top_n"`
		}
		if err := json.Unmarshal(call.Arguments, &args); err != nil {
			return protocol.ToolResult{
				Content: []protocol.TextContent{{Type: "text", Text: "invalid arguments: " + err.Error()}},
				IsError: true,
			}, nil
		}
		data, err := search.SearchIndex(args.Query, args.TopN)
		if err != nil {
			return protocol.ToolResult{
				Content: []protocol.TextContent{{Type: "text", Text: "search failed: " + err.Error()}},
				IsError: true,
			}, nil
		}
		return protocol.ToolResult{
			Content: []protocol.TextContent{{Type: "text", Text: data}},
		}, nil

	case "get_diagnostics":
		var args struct {
			Severity int `json:"severity"`
		}
		if err := json.Unmarshal(call.Arguments, &args); err != nil {
			args.Severity = 2
		}
		if args.Severity == 0 {
			args.Severity = 2
		}
		diags, err := nvim.GetDiagnostics(args.Severity)
		if err != nil {
			return protocol.ToolResult{
				Content: []protocol.TextContent{{Type: "text", Text: "failed to get diagnostics: " + err.Error()}},
				IsError: true,
			}, nil
		}
		return protocol.ToolResult{
			Content: []protocol.TextContent{{Type: "text", Text: nvim.FormatDiagnostics(diags)}},
		}, nil

	case "lg_write_file":
		var args struct {
			Path    string `json:"path"`
			OldText string `json:"old_text"`
			NewText string `json:"new_text"`
		}
		if err := json.Unmarshal(call.Arguments, &args); err != nil {
			return protocol.ToolResult{
				Content: []protocol.TextContent{{Type: "text", Text: "invalid arguments: " + err.Error()}},
				IsError: true,
			}, nil
		}
		dir := args.Path[:max(0, strings.LastIndex(args.Path, "/"))]
		if dir != "" {
			os.MkdirAll(dir, 0755)
		}
		resp, err := nvim.SendToNeovim(map[string]any{"method": "edit_file", "path": args.Path, "old_text": args.OldText, "new_text": args.NewText})
		if err != nil {
			return protocol.ToolResult{
				Content: []protocol.TextContent{{Type: "text", Text: "edit failed: " + err.Error()}},
				IsError: true,
			}, nil
		}
		var result struct {
			OK     bool   `json:"ok"`
			Status string `json:"status"`
			Error  string `json:"error"`
		}
		if err := json.Unmarshal(resp, &result); err != nil {
			return protocol.ToolResult{
				Content: []protocol.TextContent{{Type: "text", Text: string(resp)}},
			}, nil
		}
		if !result.OK {
			return protocol.ToolResult{
				Content: []protocol.TextContent{{Type: "text", Text: result.Error}},
				IsError: true,
			}, nil
		}
		return protocol.ToolResult{
			Content: []protocol.TextContent{{Type: "text", Text: "Edit " + result.Status + ": " + args.Path}},
		}, nil

	case "read_buffer":
		var args struct {
			Path      string `json:"path"`
			StartLine *int   `json:"start_line,omitempty"`
			EndLine   *int   `json:"end_line,omitempty"`
		}
		if err := json.Unmarshal(call.Arguments, &args); err != nil {
			return protocol.ToolResult{
				Content: []protocol.TextContent{{Type: "text", Text: "invalid arguments: " + err.Error()}},
				IsError: true,
			}, nil
		}
		req := map[string]any{"method": "read_buffer", "path": args.Path}
		if args.StartLine != nil {
			req["start_line"] = *args.StartLine
		}
		if args.EndLine != nil {
			req["end_line"] = *args.EndLine
		}
		resp, err := nvim.SendToNeovim(req)
		if err != nil {
			return protocol.ToolResult{
				Content: []protocol.TextContent{{Type: "text", Text: "read failed: " + err.Error()}},
				IsError: true,
			}, nil
		}
		var result struct {
			Content   string `json:"content"`
			Error     string `json:"error"`
			StartLine int    `json:"start_line"`
			EndLine   int    `json:"end_line"`
			Total     int    `json:"total_lines"`
		}
		if err := json.Unmarshal(resp, &result); err != nil {
			return protocol.ToolResult{
				Content: []protocol.TextContent{{Type: "text", Text: string(resp)}},
			}, nil
		}
		if result.Error != "" {
			return protocol.ToolResult{
				Content: []protocol.TextContent{{Type: "text", Text: result.Error}},
				IsError: true,
			}, nil
		}
		return protocol.ToolResult{
			Content: []protocol.TextContent{{Type: "text", Text: result.Content}},
		}, nil

	case "handoff_to_chat":
		var args struct {
			Plan string `json:"plan"`
		}
		if err := json.Unmarshal(call.Arguments, &args); err != nil {
			return protocol.ToolResult{
				Content: []protocol.TextContent{{Type: "text", Text: "invalid arguments: " + err.Error()}},
				IsError: true,
			}, nil
		}
		if strings.TrimSpace(args.Plan) == "" {
			return protocol.ToolResult{
				Content: []protocol.TextContent{{Type: "text", Text: "plan is required"}},
				IsError: true,
			}, nil
		}
		if _, err := nvim.SendToNeovim(map[string]any{"method": "handoff_to_chat", "plan": args.Plan}); err != nil {
			return protocol.ToolResult{
				Content: []protocol.TextContent{{Type: "text", Text: "handoff failed: " + err.Error()}},
				IsError: true,
			}, nil
		}
		return protocol.ToolResult{
			Content: []protocol.TextContent{{Type: "text", Text: "Handoff queued. Respond briefly that you are handing off to the execution agent, then end your turn — lg will switch to lg-chat and execute the plan."}},
		}, nil

	case "lg_paint_regions":
		var args struct {
			Regions []struct {
				File        string `json:"file"`
				StartLine   int    `json:"start_line"`
				EndLine     int    `json:"end_line"`
				Description string `json:"description"`
			} `json:"regions"`
		}
		if err := json.Unmarshal(call.Arguments, &args); err != nil {
			return protocol.ToolResult{
				Content: []protocol.TextContent{{Type: "text", Text: "invalid arguments: " + err.Error()}},
				IsError: true,
			}, nil
		}
		resp, err := nvim.SendToNeovim(map[string]any{"method": "paint_regions", "regions": args.Regions})
		if err != nil {
			return protocol.ToolResult{
				Content: []protocol.TextContent{{Type: "text", Text: "paint failed: " + err.Error()}},
				IsError: true,
			}, nil
		}
		return protocol.ToolResult{
			Content: []protocol.TextContent{{Type: "text", Text: string(resp)}},
		}, nil

	default:
		return nil, fmt.Errorf("unknown tool: %s", call.Name)
	}
}

func handleToolsList() any {
	f := false
	return struct {
		Tools []protocol.ToolDef `json:"tools"`
	}{
		Tools: []protocol.ToolDef{
			{
				Name:        "paint_edit",
				Description: "Replace code in painted regions. Call get_painted_regions first. Send ALL edits in one call. If the user rejects an edit via the permission prompt, do NOT retry the same edit with this or any other tool.",
				InputSchema: protocol.ToolSchema{
					Type: "object",
					Properties: map[string]any{
						"edits": map[string]any{
							"type": "array",
							"items": map[string]any{
								"type": "object",
								"properties": map[string]any{
									"region_id": map[string]any{"type": "integer", "description": "0-based region index"},
									"new_code":  map[string]string{"type": "string", "description": "Full replacement code"},
								},
								"required":             []string{"region_id", "new_code"},
								"additionalProperties": false,
							},
						},
						"edit_token": map[string]string{"type": "string", "description": "Edit token from prompt. Pass it exactly if provided."},
					},
					Required:             []string{"edits"},
					AdditionalProperties: &f,
				},
			},
			{
				Name:        "get_painted_regions",
				Description: "List painted regions with their code content.",
				InputSchema: protocol.ToolSchema{
					Type: "object",
					Properties: map[string]any{
						"edit_token": map[string]string{"type": "string", "description": "Edit token from prompt. Pass it exactly if provided."},
					},
					Required: []string{},
				},
			},
			{
				Name:        "lg_search_codebase",
				Description: "Semantic search over codebase via embeddings.",
				InputSchema: protocol.ToolSchema{
					Type: "object",
					Properties: map[string]any{
						"query": map[string]string{"type": "string", "description": "Search query"},
						"top_n": map[string]any{"type": "integer", "description": "Results count (default 5)"},
					},
					Required:             []string{"query"},
					AdditionalProperties: &f,
				},
			},
			{
				Name:        "get_diagnostics",
				Description: "Get LSP diagnostics from open buffers. Only use when explicitly asked.",
				InputSchema: protocol.ToolSchema{
					Type: "object",
					Properties: map[string]any{
						"severity": map[string]any{"type": "integer", "description": "Min severity: 1=Error 2=Warn 3=Info 4=Hint"},
					},
					Required:             []string{},
					AdditionalProperties: &f,
				},
			},
			{
				Name:        "lg_write_file",
				Description: "Edit a file by replacing a text snippet. Shows an inline diff for user review. Only the changed portion is needed — not the whole file. If the user rejects, do NOT retry.",
				InputSchema: protocol.ToolSchema{
					Type: "object",
					Properties: map[string]any{
						"path":     map[string]string{"type": "string", "description": "Absolute file path"},
						"old_text": map[string]string{"type": "string", "description": "Exact text to find and replace (include enough context for a unique match)"},
						"new_text": map[string]string{"type": "string", "description": "Replacement text"},
					},
					Required:             []string{"path", "old_text", "new_text"},
					AdditionalProperties: &f,
				},
			},
			{
				Name:        "read_buffer",
				Description: "Read file content. Returns buffer content (includes unsaved changes) if the file is open in the editor, otherwise reads from disk.",
				InputSchema: protocol.ToolSchema{
					Type: "object",
					Properties: map[string]any{
						"path":       map[string]string{"type": "string", "description": "Absolute file path"},
						"start_line": map[string]any{"type": "integer", "description": "Start line (1-based, optional)"},
						"end_line":   map[string]any{"type": "integer", "description": "End line (1-based inclusive, optional)"},
					},
					Required:             []string{"path"},
					AdditionalProperties: &f,
				},
			},
			{
				Name:        "handoff_to_chat",
				Description: "Hand off an approved plan to the execution agent (lg-chat). Call this ONLY after the user has confirmed the plan. Pass the plan text so the execution agent has full context. After calling this, respond briefly and end your turn — lg will auto-switch to lg-chat and run the plan.",
				InputSchema: protocol.ToolSchema{
					Type: "object",
					Properties: map[string]any{
						"plan": map[string]string{"type": "string", "description": "The full confirmed plan in plain text. Include file paths, old_text/new_text sketches, and any caveats."},
					},
					Required:             []string{"plan"},
					AdditionalProperties: &f,
				},
			},
			{
				Name:        "lg_paint_regions",
				Description: "Highlight code regions in Neovim. Opens files if needed.",
				InputSchema: protocol.ToolSchema{
					Type: "object",
					Properties: map[string]any{
						"regions": map[string]any{
							"type": "array",
							"items": map[string]any{
								"type": "object",
								"properties": map[string]any{
									"file":        map[string]string{"type": "string", "description": "Absolute path"},
									"start_line":  map[string]string{"type": "integer", "description": "Start line (1-based)"},
									"end_line":    map[string]string{"type": "integer", "description": "End line (1-based, inclusive)"},
									"description": map[string]string{"type": "string", "description": "One sentence summary (max 80 chars)"},
								},
								"required": []string{"file", "start_line", "end_line"},
							},
						},
					},
					Required:             []string{"regions"},
					AdditionalProperties: &f,
				},
			},
		},
	}
}

func main() {
	nvim.SockPath = os.Getenv("LG_SOCK")
	nvim.SessionID = os.Getenv("LG_SESSION")
	search.IndexURL = os.Getenv("LG_INDEX_URL")

	if nvim.SockPath == "" {
		fmt.Fprintf(os.Stderr, "LG_SOCK not set\n")
		os.Exit(1)
	}

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
				"serverInfo":      map[string]any{"name": "lg-mcp", "version": "0.2.0"},
			}
		case "notifications/initialized":
			continue
		case "tools/list":
			resp.Result = handleToolsList()
		case "tools/call":
			result, callErr := handleToolCall(req.Params)
			if callErr != nil {
				resp.Error = protocol.MCPError{Code: -32603, Message: callErr.Error()}
			} else {
				resp.Result = result
			}
		default:
			resp.Error = protocol.MCPError{Code: -32601, Message: "method not found: " + req.Method}
		}

		out, _ := json.Marshal(resp)
		fmt.Println(string(out))
	}
}
