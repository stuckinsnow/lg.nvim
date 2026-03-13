// Package protocol defines ACP JSON-RPC message types and builders.
package protocol

import (
	"encoding/json"
)

// Message is a generic JSON-RPC 2.0 message (request, response, or notification).
type Message struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      *RPCID          `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *RPCError       `json:"error,omitempty"`
}

// RPCID handles JSON-RPC ids that can be int or string.
type RPCID struct {
	raw json.RawMessage
	num int // parsed int value for map lookups, -1 if string
}

func NewID(id int) *RPCID {
	data, _ := json.Marshal(id)
	return &RPCID{raw: data, num: id}
}

func NewStringID(s string) *RPCID {
	data, _ := json.Marshal(s)
	return &RPCID{raw: data, num: -1}
}

func (r RPCID) MarshalJSON() ([]byte, error) {
	return r.raw, nil
}

func (r *RPCID) UnmarshalJSON(data []byte) error {
	r.raw = append(json.RawMessage{}, data...)
	if err := json.Unmarshal(data, &r.num); err != nil {
		r.num = -1
	}
	return nil
}

// IntVal returns the integer value, or -1 if the ID is a string.
func (r *RPCID) IntVal() int { return r.num }

type RPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// IsResponse returns true if this message is a response (has id, no method).
func (m *Message) IsResponse() bool { return m.ID != nil && m.Method == "" }

// IsRequest returns true if this message is a request (has id and method).
func (m *Message) IsRequest() bool { return m.ID != nil && m.Method != "" }

// IsNotification returns true if this message is a notification (has method, no id).
func (m *Message) IsNotification() bool { return m.ID == nil && m.Method != "" }

// SessionNewResult is the result of session/new.
type SessionNewResult struct {
	SessionID string       `json:"sessionId"`
	Models    *ModelsInfo  `json:"models,omitempty"`
}

type ModelsInfo struct {
	CurrentModelID  string       `json:"currentModelId"`
	AvailableModels []ModelInfo  `json:"availableModels"`
}

type ModelInfo struct {
	ModelID string `json:"modelId"`
}

// SessionUpdateParams wraps session/update notification params.
type SessionUpdateParams struct {
	SessionID string          `json:"sessionId"`
	Update    json.RawMessage `json:"update"`
}

// SessionUpdate is the inner update payload.
type SessionUpdate struct {
	SessionUpdate string          `json:"sessionUpdate"`
	Content       *ContentBlock   `json:"content,omitempty"`
	Title         string          `json:"title,omitempty"`
	ToolCallID    string          `json:"toolCallId,omitempty"`
	Status        string          `json:"status,omitempty"`
	Message       string          `json:"message,omitempty"`
}

type ContentBlock struct {
	Type string `json:"type"`
	Text string `json:"text,omitempty"`
}

// PromptResult is the result of session/prompt.
type PromptResult struct {
	StopReason string `json:"stopReason"`
}

// PermissionParams wraps session/request_permission params.
type PermissionParams struct {
	SessionID string             `json:"sessionId"`
	ToolCall  *PermissionTool    `json:"toolCall,omitempty"`
	Options   []PermissionOption `json:"options"`
}

type PermissionTool struct {
	Title string `json:"title"`
}

type PermissionOption struct {
	OptionID string `json:"optionId"`
	Kind     string `json:"kind"`
}

// FSReadParams wraps fs/read_text_file params.
type FSReadParams struct {
	Path string `json:"path"`
}

// FSWriteParams wraps fs/write_text_file params.
type FSWriteParams struct {
	Path    string `json:"path"`
	Content string `json:"content"`
}

// --- Builders ---

func InitializeRequest(id int, clientName string) Message {
	params, _ := json.Marshal(map[string]any{
		"protocolVersion":    1,
		"clientCapabilities": map[string]any{"fs": map[string]any{"readTextFile": true, "writeTextFile": false}},
		"clientInfo":         map[string]any{"name": clientName, "version": "2.0.0"},
	})
	return Message{JSONRPC: "2.0", ID: NewID(id), Method: "initialize", Params: params}
}

func SessionNewRequest(id int, cwd string, mcpServers map[string]any) Message {
	params := map[string]any{"cwd": cwd}
	if len(mcpServers) > 0 {
		params["mcpServers"] = mcpServers
	} else {
		params["mcpServers"] = []any{}
	}
	data, _ := json.Marshal(params)
	return Message{JSONRPC: "2.0", ID: NewID(id), Method: "session/new", Params: data}
}

func SessionPromptRequest(id int, sessionID string, prompt json.RawMessage) Message {
	params, _ := json.Marshal(map[string]any{"sessionId": sessionID, "prompt": prompt})
	return Message{JSONRPC: "2.0", ID: NewID(id), Method: "session/prompt", Params: params}
}

func SessionSetModeRequest(id int, sessionID, modeID string) Message {
	params, _ := json.Marshal(map[string]any{"sessionId": sessionID, "modeId": modeID})
	return Message{JSONRPC: "2.0", ID: NewID(id), Method: "session/set_mode", Params: params}
}

func SessionSetModelRequest(id int, sessionID, modelID string) Message {
	params, _ := json.Marshal(map[string]any{"sessionId": sessionID, "modelId": modelID})
	return Message{JSONRPC: "2.0", ID: NewID(id), Method: "session/set_model", Params: params}
}

func SessionCancelNotification(sessionID string) Message {
	params, _ := json.Marshal(map[string]any{"sessionId": sessionID})
	return Message{JSONRPC: "2.0", Method: "session/cancel", Params: params}
}

func PermissionResponse(id *RPCID, optionID string) Message {
	result, _ := json.Marshal(map[string]any{"outcome": map[string]any{"outcome": "selected", "optionId": optionID}})
	return Message{JSONRPC: "2.0", ID: id, Result: result}
}

func FSReadResponse(id *RPCID, content string) Message {
	result, _ := json.Marshal(map[string]any{"content": content})
	return Message{JSONRPC: "2.0", ID: id, Result: result}
}

func FSWriteResponse(id *RPCID) Message {
	return Message{JSONRPC: "2.0", ID: id, Result: json.RawMessage("null")}
}
