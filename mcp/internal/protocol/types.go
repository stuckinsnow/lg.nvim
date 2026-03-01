package protocol

import "encoding/json"

type JSONRPCRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      any             `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type JSONRPCResponse struct {
	JSONRPC string `json:"jsonrpc"`
	ID      any    `json:"id"`
	Result  any    `json:"result,omitempty"`
	Error   any    `json:"error,omitempty"`
}

type MCPError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type ToolDef struct {
	Name        string     `json:"name"`
	Description string     `json:"description"`
	InputSchema ToolSchema `json:"inputSchema"`
}

type ToolSchema struct {
	Type                 string         `json:"type"`
	Properties           map[string]any `json:"properties"`
	Required             []string       `json:"required"`
	AdditionalProperties *bool          `json:"additionalProperties,omitempty"`
}

type TextContent struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

type ToolResult struct {
	Content []TextContent `json:"content"`
	IsError bool          `json:"isError,omitempty"`
}

type NvimRegion struct {
	RegionID  int      `json:"region_id"`
	File      string   `json:"file"`
	StartLine int      `json:"start_line"`
	EndLine   int      `json:"end_line"`
	Lines     []string `json:"lines"`
}

type NvimEdit struct {
	RegionID int    `json:"region_id"`
	NewCode  string `json:"new_code"`
}

type Diagnostic struct {
	File     string `json:"file"`
	Line     int    `json:"line"`
	Col      int    `json:"col"`
	Severity string `json:"severity"`
	Message  string `json:"message"`
	Source   string `json:"source"`
}
