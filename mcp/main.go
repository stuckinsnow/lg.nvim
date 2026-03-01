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
				Description: "Replace code in painted regions. Call get_painted_regions first. Send ALL edits in one call.",
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
