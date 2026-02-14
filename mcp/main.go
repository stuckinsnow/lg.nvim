package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
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

type mcpError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type toolDef struct {
	Name        string     `json:"name"`
	Description string     `json:"description"`
	InputSchema toolSchema `json:"inputSchema"`
}

type toolSchema struct {
	Type                 string              `json:"type"`
	Properties           map[string]any      `json:"properties"`
	Required             []string            `json:"required"`
	AdditionalProperties *bool               `json:"additionalProperties,omitempty"`
}

type textContent struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

type toolResult struct {
	Content []textContent `json:"content"`
	IsError bool          `json:"isError,omitempty"`
}

type nvimRegion struct {
	RegionID  int      `json:"region_id"`
	File      string   `json:"file"`
	StartLine int      `json:"start_line"`
	EndLine   int      `json:"end_line"`
	Lines     []string `json:"lines"`
}

type nvimEdit struct {
	RegionID int    `json:"region_id"`
	NewCode  string `json:"new_code"`
}

type nvimBatchRequest struct {
	Method string     `json:"method"`
	Edits  []nvimEdit `json:"edits"`
}

var sockPath string

func init() {
	sockPath = os.Getenv("LG_SOCK")
}

func sendToNeovim(req any) ([]byte, error) {
	conn, err := net.Dial("unix", sockPath)
	if err != nil {
		return nil, fmt.Errorf("connect to neovim socket: %w", err)
	}
	defer conn.Close()

	data, _ := json.Marshal(req)
	data = append(data, '\n')
	if _, err := conn.Write(data); err != nil {
		return nil, err
	}

	reader := bufio.NewReader(conn)
	return reader.ReadBytes('\n')
}

func getRegions() ([]nvimRegion, error) {
	resp, err := sendToNeovim(map[string]string{"method": "get_regions"})
	if err != nil {
		return nil, err
	}
	var regions []nvimRegion
	if err := json.Unmarshal(resp, &regions); err != nil {
		return nil, err
	}
	return regions, nil
}

func applyEdits(edits []nvimEdit) error {
	resp, err := sendToNeovim(nvimBatchRequest{Method: "apply_edits", Edits: edits})
	if err != nil {
		return err
	}
	var result struct {
		OK    bool   `json:"ok"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal(resp, &result); err != nil {
		return err
	}
	if result.Error != "" {
		return fmt.Errorf("%s", result.Error)
	}
	return nil
}

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
			Edits []nvimEdit `json:"edits"`
		}
		if err := json.Unmarshal(call.Arguments, &args); err != nil {
			return toolResult{
				Content: []textContent{{Type: "text", Text: "invalid arguments: " + err.Error()}},
				IsError: true,
			}, nil
		}

		if err := applyEdits(args.Edits); err != nil {
			return toolResult{
				Content: []textContent{{Type: "text", Text: "edit failed: " + err.Error()}},
				IsError: true,
			}, nil
		}

		return toolResult{
			Content: []textContent{{Type: "text", Text: fmt.Sprintf("%d region(s) updated", len(args.Edits))}},
		}, nil

	case "get_painted_regions":
		regions, err := getRegions()
		if err != nil {
			return toolResult{
				Content: []textContent{{Type: "text", Text: "failed to get regions: " + err.Error()}},
				IsError: true,
			}, nil
		}
		data, _ := json.MarshalIndent(regions, "", "  ")
		return toolResult{
			Content: []textContent{{Type: "text", Text: string(data)}},
		}, nil

	default:
		return nil, fmt.Errorf("unknown tool: %s", call.Name)
	}
}

func handleToolsList() any {
	f := false
	return struct {
		Tools []toolDef `json:"tools"`
	}{
		Tools: []toolDef{
			{
				Name:        "paint_edit",
				Description: "Replace code in painted regions in Neovim. Send ALL edits in one call. Call get_painted_regions first to see available regions.",
				InputSchema: toolSchema{
					Type: "object",
					Properties: map[string]any{
						"edits": map[string]any{
							"type":        "array",
							"description": "Array of edits, one per region",
							"items": map[string]any{
								"type": "object",
								"properties": map[string]any{
									"region_id": map[string]string{"type": "integer", "description": "0-based index of the painted region"},
									"new_code":  map[string]string{"type": "string", "description": "Complete replacement code for this region"},
								},
								"required":             []string{"region_id", "new_code"},
								"additionalProperties": false,
							},
						},
					},
					Required:             []string{"edits"},
					AdditionalProperties: &f,
				},
			},
			{
				Name:        "get_painted_regions",
				Description: "List all currently painted regions in Neovim with their code content.",
				InputSchema: toolSchema{
					Type:       "object",
					Properties: map[string]any{},
					Required:   []string{},
				},
			},
		},
	}
}

func main() {
	if sockPath == "" {
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
				"serverInfo":      map[string]any{"name": "lg-mcp", "version": "0.2.0"},
			}
		case "notifications/initialized":
			continue
		case "tools/list":
			resp.Result = handleToolsList()
		case "tools/call":
			result, callErr := handleToolCall(req.Params)
			if callErr != nil {
				resp.Error = mcpError{Code: -32603, Message: callErr.Error()}
			} else {
				resp.Result = result
			}
		default:
			resp.Error = mcpError{Code: -32601, Message: "method not found: " + req.Method}
		}

		out, _ := json.Marshal(resp)
		fmt.Println(string(out))
	}
}
