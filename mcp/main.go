package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
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

var (
	sockPath   string
	indexURL   string
	sessionID  string
)

func init() {
	sockPath = os.Getenv("LG_SOCK")
	indexURL = os.Getenv("LG_INDEX_URL")
	sessionID = os.Getenv("LG_SESSION")
}

func detectGitInfo() (repo, branch, head string) {
	if out, err := exec.Command("git", "remote", "get-url", "origin").Output(); err == nil {
		s := strings.TrimSpace(string(out))
		if i := strings.LastIndex(s, "/"); i >= 0 {
			repo = strings.TrimSuffix(s[i+1:], ".git")
		}
	}
	if out, err := exec.Command("git", "branch", "--show-current").Output(); err == nil {
		branch = strings.TrimSpace(string(out))
	}
	if branch != "" {
		if out, err := exec.Command("git", "rev-parse", "origin/"+branch).Output(); err == nil {
			head = strings.TrimSpace(string(out))
		}
	}
	return
}

func searchIndex(query string, topN int) (string, error) {
	repo, branch, head := detectGitInfo()
	if repo == "" {
		return "", fmt.Errorf("cannot detect git repo")
	}
	if topN == 0 {
		topN = 15
	}
	body, _ := json.Marshal(map[string]any{
		"repo": repo, "branch": branch, "query": query, "top_n": topN, "head": head,
	})
	resp, err := http.Post(indexURL+"/find", "application/json", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		return "", fmt.Errorf("index API: %s", string(data))
	}
	var results []struct {
		File      string  `json:"file"`
		StartLine int     `json:"start_line"`
		EndLine   int     `json:"end_line"`
		Score     float64 `json:"score"`
		Content   string  `json:"content"`
	}
	if err := json.Unmarshal(data, &results); err != nil {
		return "", err
	}
	if len(results) == 0 {
		return "No results found.", nil
	}
	var sb strings.Builder
	fullCount := 5
	if fullCount > len(results) {
		fullCount = len(results)
	}
	for i := 0; i < fullCount; i++ {
		r := results[i]
		ext := ""
		if i := strings.LastIndex(r.File, "."); i >= 0 {
			ext = r.File[i+1:]
		}
		fmt.Fprintf(&sb, "### %s (lines %d-%d, score: %.2f)\n```%s\n%s\n```\n\n", r.File, r.StartLine, r.EndLine, r.Score, ext, r.Content)
	}
	var refs []string
	for i := fullCount; i < len(results); i++ {
		r := results[i]
		if r.Score < 0.3 {
			break
		}
		refs = append(refs, fmt.Sprintf("- %s (lines %d-%d, score: %.2f)", r.File, r.StartLine, r.EndLine, r.Score))
	}
	if len(refs) > 0 {
		sb.WriteString("### Also relevant\n")
		sb.WriteString(strings.Join(refs, "\n"))
		sb.WriteString("\n")
	}
	return sb.String(), nil
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
	req := map[string]string{"method": "get_regions"}
	if sessionID != "" {
		req["session"] = sessionID
	}
	resp, err := sendToNeovim(req)
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
	req := map[string]any{"method": "apply_edits", "edits": edits}
	if sessionID != "" {
		req["session"] = sessionID
	}
	resp, err := sendToNeovim(req)
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

	case "lg_search_codebase":
		if indexURL == "" {
			return toolResult{
				Content: []textContent{{Type: "text", Text: "LG_INDEX_URL not set"}},
				IsError: true,
			}, nil
		}
		var args struct {
			Query string `json:"query"`
			TopN  int    `json:"top_n"`
		}
		if err := json.Unmarshal(call.Arguments, &args); err != nil {
			return toolResult{
				Content: []textContent{{Type: "text", Text: "invalid arguments: " + err.Error()}},
				IsError: true,
			}, nil
		}
		data, err := searchIndex(args.Query, args.TopN)
		if err != nil {
			return toolResult{
				Content: []textContent{{Type: "text", Text: "search failed: " + err.Error()}},
				IsError: true,
			}, nil
		}
		return toolResult{
			Content: []textContent{{Type: "text", Text: data}},
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
		diags, err := getDiagnostics(args.Severity)
		if err != nil {
			return toolResult{
				Content: []textContent{{Type: "text", Text: "failed to get diagnostics: " + err.Error()}},
				IsError: true,
			}, nil
		}
		return toolResult{
			Content: []textContent{{Type: "text", Text: formatDiagnostics(diags)}},
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
			return toolResult{
				Content: []textContent{{Type: "text", Text: "invalid arguments: " + err.Error()}},
				IsError: true,
			}, nil
		}
		resp, err := sendToNeovim(map[string]any{"method": "paint_regions", "regions": args.Regions})
		if err != nil {
			return toolResult{
				Content: []textContent{{Type: "text", Text: "paint failed: " + err.Error()}},
				IsError: true,
			}, nil
		}
		return toolResult{
			Content: []textContent{{Type: "text", Text: string(resp)}},
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
				Description: "Replace code in painted regions. Call get_painted_regions first. Send ALL edits in one call.",
				InputSchema: toolSchema{
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
					},
					Required:             []string{"edits"},
					AdditionalProperties: &f,
				},
			},
			{
				Name:        "get_painted_regions",
				Description: "List painted regions with their code content.",
				InputSchema: toolSchema{
					Type:       "object",
					Properties: map[string]any{},
					Required:   []string{},
				},
			},
			{
				Name:        "lg_search_codebase",
				Description: "Semantic search over codebase via embeddings.",
				InputSchema: toolSchema{
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
				InputSchema: toolSchema{
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
				InputSchema: toolSchema{
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
