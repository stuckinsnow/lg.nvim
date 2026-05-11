// Package protocol defines ACP JSON-RPC message types and builders.
package protocol

import "encoding/json"

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
	num int
}

func NewID(id int) *RPCID {
	data, _ := json.Marshal(id)
	return &RPCID{raw: data, num: id}
}

func NewStringID(s string) *RPCID {
	data, _ := json.Marshal(s)
	return &RPCID{raw: data, num: -1}
}

func (r RPCID) MarshalJSON() ([]byte, error) { return r.raw, nil }

func (r *RPCID) UnmarshalJSON(data []byte) error {
	r.raw = append(json.RawMessage{}, data...)
	if err := json.Unmarshal(data, &r.num); err != nil {
		r.num = -1
	}
	return nil
}

func (r *RPCID) IntVal() int { return r.num }

type RPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (m *Message) IsResponse() bool     { return m.ID != nil && m.Method == "" }
func (m *Message) IsRequest() bool      { return m.ID != nil && m.Method != "" }
func (m *Message) IsNotification() bool { return m.ID == nil && m.Method != "" }

// SessionNewResult is the result of session/new.
type SessionNewResult struct {
	SessionID string      `json:"sessionId"`
	Models    *ModelsInfo `json:"models,omitempty"`
}

type ModelsInfo struct {
	CurrentModelID  string      `json:"currentModelId"`
	AvailableModels []ModelInfo `json:"availableModels"`
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
	SessionUpdate string        `json:"sessionUpdate"`
	Content       *ContentBlock `json:"content,omitempty"`
	Title         string        `json:"title,omitempty"`
	ToolCallID    string        `json:"toolCallId,omitempty"`
	Status        string        `json:"status,omitempty"`
	Message       string        `json:"message,omitempty"`
}

type ContentBlock struct {
	Type string `json:"type"`
	Text string `json:"text,omitempty"`
}

type PromptResult struct {
	StopReason string `json:"stopReason"`
}

// PermissionParams wraps session/request_permission params.
type PermissionParams struct {
	SessionID string             `json:"sessionId"`
	ToolCall  *PermissionTool    `json:"toolCall,omitempty"`
	Options   []PermissionOption `json:"options"`
	Meta      *PermissionMeta    `json:"_meta,omitempty"`
}

type PermissionMeta struct {
	TrustOptions []TrustOption `json:"trustOptions,omitempty"`
}

type TrustOption struct {
	Label   string `json:"label"`
	Display string `json:"display"`
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
