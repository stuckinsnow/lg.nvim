package session

import (
	"encoding/json"
	"lg-acp/internal/process"
	"lg-acp/internal/protocol"
	"sync"
)

// State represents the session lifecycle.
type State string

const (
	StateCreating  State = "creating"
	StateActive    State = "active"
	StateCompleted State = "completed"
	StateCancelled State = "cancelled"
)

// Event is streamed back to the Lua client over the socket.
type Event struct {
	Type      string          `json:"type"`
	SessionID string          `json:"session_id,omitempty"`
	Data      json.RawMessage `json:"data,omitempty"`
	Text      string          `json:"text,omitempty"`
	Error     string          `json:"error,omitempty"`
}

// Session is a single ACP session on a shared process.
type Session struct {
	ID    string
	State State
	proc  *process.Process
	Guard *AccessGuard

	// Provider is "kiro", "opencode", "cursor", etc. Set at creation.
	Provider string
	// LogicalMode is the lg-level mode name (e.g. "reviewer", "lg-chat").
	// Cursor/opencode only have a few native modes (agent/plan/ask or build/plan),
	// so the logical mode is preserved separately for client-side tool scoping.
	LogicalMode string

	mu             sync.Mutex
	pendingUpdates []*protocol.Message
	events         chan Event
	promptCount    int
	onDone         map[int]func()
	pendingPerms   map[int]*protocol.RPCID
	nextPermKey    int
}

// Manager owns the shared process and all sessions.
type Manager struct {
	proc     *process.Process
	mu       sync.Mutex
	sessions map[string]*Session
	nextTemp int64

	cmd        []string
	clientName string
	provider   string
	mcpServers map[string]any
}
