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

func (m *Message) IsResponse() bool     { return m.ID != nil && m.Method == "" }
func (m *Message) IsRequest() bool      { return m.ID != nil && m.Method != "" }
func (m *Message) IsNotification() bool { return m.ID == nil && m.Method != "" }

// SessionNewResult is the result of session/new.
type SessionNewResult struct {
	SessionID string `json:"sessionId"`
	Modes     struct {
		CurrentModeID string `json:"currentModeId"`
	} `json:"modes"`
}

type ModelsInfo struct {
	CurrentModelID  string      `json:"currentModelId"`
	AvailableModels []ModelInfo `json:"availableModels"`
}

type ModelInfo struct {
	ModelID        string  `json:"modelId"`
	Name           string  `json:"name,omitempty"`
	RateMultiplier float64 `json:"rateMultiplier,omitempty"`
}

// ParseModelsInfo extracts model info from a session/new, session/load or
// set_config_option result. It prefers the `models.availableModels` field. When
// that is empty — as with kiro v3 and opencode 1.17+, which both carry the model
// list in `configOptions` — it falls back to the `configOptions` entry whose id
// is "model".
func ParseModelsInfo(raw json.RawMessage) *ModelsInfo {
	if len(raw) == 0 {
		return nil
	}
	var parsed struct {
		Models        *ModelsInfo `json:"models"`
		ConfigOptions []struct {
			ID           string `json:"id"`
			CurrentValue string `json:"currentValue"`
			Options      []struct {
				Value string `json:"value"`
				Name  string `json:"name"`
				Meta  struct {
					Kiro struct {
						RateMultiplier float64 `json:"rateMultiplier"`
					} `json:"kiro"`
				} `json:"_meta"`
			} `json:"options"`
		} `json:"configOptions"`
	}
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return nil
	}
	// Preferred: availableModels.
	if parsed.Models != nil && len(parsed.Models.AvailableModels) > 0 {
		return parsed.Models
	}
	// Fallback: configOptions model select (kiro v3, opencode).
	for _, co := range parsed.ConfigOptions {
		if co.ID != "model" {
			continue
		}
		mi := &ModelsInfo{CurrentModelID: co.CurrentValue}
		for _, o := range co.Options {
			mi.AvailableModels = append(mi.AvailableModels, ModelInfo{
				ModelID:        o.Value,
				Name:           o.Name,
				RateMultiplier: o.Meta.Kiro.RateMultiplier,
			})
		}
		if len(mi.AvailableModels) > 0 {
			return mi
		}
	}
	// Last resort: preserve whatever models block existed (may carry currentModelId).
	return parsed.Models
}

// SessionUpdateParams wraps session/update notification params.
type SessionUpdateParams struct {
	SessionID string          `json:"sessionId"`
	Update    json.RawMessage `json:"update"`
}

// ToolLocation is a file/line reference attached to an ACP tool_call update.
type ToolLocation struct {
	Path string `json:"path,omitempty"`
	Line int    `json:"line,omitempty"`
}

// SessionUpdate is the inner update payload.
type SessionUpdate struct {
	SessionUpdate string          `json:"sessionUpdate"`
	Content       *ContentBlock   `json:"content,omitempty"`
	Title         string          `json:"title,omitempty"`
	ToolCallID    string          `json:"toolCallId,omitempty"`
	Status        string          `json:"status,omitempty"`
	Message       string          `json:"message,omitempty"`
	RawInput      json.RawMessage `json:"rawInput,omitempty"`
	Locations     []ToolLocation  `json:"locations,omitempty"`

	// current_mode_update
	CurrentModeID string `json:"currentModeId,omitempty"`
	// config_option_update
	ConfigOptions []ConfigOption `json:"configOptions,omitempty"`
	// available_commands_update
	AvailableCommands []struct {
		Name string `json:"name"`
	} `json:"availableCommands,omitempty"`
	// usage_update (antigravity)
	Used *int64 `json:"used,omitempty"`
	Size *int64 `json:"size,omitempty"`

	Meta struct {
		Kiro KiroUpdateMeta `json:"kiro"`
	} `json:"_meta"`
}

// ConfigOption is one entry of a configOptions list (mode, model, ...).
type ConfigOption struct {
	ID           string `json:"id"`
	CurrentValue string `json:"currentValue"`
}

// KiroUpdateMeta is the `_meta.kiro` block kiro v3 attaches to updates.
// session_info_update dispatches on Kind.
type KiroUpdateMeta struct {
	Kind         string `json:"kind"`
	Replay       bool   `json:"replay"`
	ContextUsage *struct {
		UsagePercentage float64 `json:"usagePercentage"`
	} `json:"contextUsage"`
	// turn_completion
	PromptTurnSummaries []struct {
		Usage      float64 `json:"usage"`
		Unit       string  `json:"unit"`
		UnitPlural string  `json:"unitPlural"`
	} `json:"promptTurnSummaries"`
	ElapsedTime int64 `json:"elapsedTime"`
	// failed tool_call_update: cancelled, denied or error
	FailureReason string `json:"failureReason"`
}

type ContentBlock struct {
	Type string `json:"type"`
	Text string `json:"text,omitempty"`
}

type PromptUsage struct {
	InputTokens      int64 `json:"inputTokens"`
	OutputTokens     int64 `json:"outputTokens"`
	CachedReadTokens int64 `json:"cachedReadTokens"`
	ThoughtTokens    int64 `json:"thoughtTokens"`
	TotalTokens      int64 `json:"totalTokens"`
}

type PromptResult struct {
	StopReason string       `json:"stopReason"`
	Usage      *PromptUsage `json:"usage,omitempty"`
}

// PermissionParams wraps session/request_permission params.
type PermissionParams struct {
	SessionID string             `json:"sessionId"`
	ToolCall  *PermissionTool    `json:"toolCall,omitempty"`
	Options   []PermissionOption `json:"options"`
	Meta      *PermissionMeta    `json:"_meta,omitempty"`
}

type PermissionMeta struct {
	Kiro struct {
		// Consent says what the tool wants to do: capability is fs_read,
		// fs_write, shell, mcp, web_fetch, ...; resource is the path, command
		// or "server/tool" it applies to.
		Consent *struct {
			Capability    string `json:"capability"`
			Resource      string `json:"resource"`
			WorkspaceRoot string `json:"workspaceRoot"`
		} `json:"consent"`
	} `json:"kiro"`
}

type PermissionTool struct {
	Title string `json:"title"`
	Kind  string `json:"kind,omitempty"`
}

type PermissionOption struct {
	OptionID string `json:"optionId"`
	Kind     string `json:"kind"`
}

// FSReadParams wraps fs/read_text_file params. Line is 1-based; zero values
// mean "from the start" and "to the end".
type FSReadParams struct {
	Path  string `json:"path"`
	Line  int    `json:"line,omitempty"`
	Limit int    `json:"limit,omitempty"`
}
