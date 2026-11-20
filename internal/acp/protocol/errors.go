package protocol

import (
	"encoding/json"
	"strings"
)

// RPCError is the JSON-RPC 2.0 error object.
type RPCError struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data,omitempty"`
}

// Detail returns the most descriptive text available for an error. Agents like
// kiro-cli put a generic "Internal error" in Message and the real cause in Data,
// so prefer Data whenever it carries anything useful.
func (e *RPCError) Detail() string {
	if e == nil {
		return ""
	}
	if len(e.Data) > 0 {
		var s string
		if err := json.Unmarshal(e.Data, &s); err == nil && s != "" {
			return s
		}
		trimmed := strings.TrimSpace(string(e.Data))
		if trimmed != "" && trimmed != "null" && trimmed != "{}" {
			return e.Message + ": " + trimmed
		}
	}
	return e.Message
}
