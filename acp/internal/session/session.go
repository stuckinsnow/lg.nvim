// Package session manages ACP session lifecycle and state.
//
// Each session tracks: creation, prompting, mode/model switching,
// permission handling, fs operations, and streaming updates.
package session

import (
	"encoding/json"
	"fmt"
	"lg-acp/internal/protocol"
	"lg-acp/internal/process"
	"log"
	"os"
	"strings"
	"sync"
	"sync/atomic"
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

	mu             sync.Mutex
	pendingUpdates []*protocol.Message
	events         chan Event
	promptCount    int
	onDone         map[int]func()              // rpc id -> callback
	pendingPerms   map[int]*protocol.RPCID      // lua-facing int key -> original RPCID
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
	mcpServers map[string]any
}

// NewManager creates a session manager for the given ACP command.
func NewManager(cmd []string, clientName string) *Manager {
	return &Manager{
		cmd:        cmd,
		clientName: clientName,
		sessions:   make(map[string]*Session),
		mcpServers: make(map[string]any),
	}
}

// SetMCPServers configures MCP servers for new sessions.
func (m *Manager) SetMCPServers(servers map[string]any) {
	m.mu.Lock()
	m.mcpServers = servers
	m.mu.Unlock()
}

// ensureProcess spawns the ACP subprocess if not already running.
func (m *Manager) ensureProcess() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.proc != nil {
		return nil
	}
	proc, err := process.Spawn(m.cmd, m.clientName)
	if err != nil {
		return err
	}
	m.proc = proc
	return nil
}

// CreateSession creates a new ACP session and returns it.
// The session's Events channel streams updates back to the caller.
func (m *Manager) CreateSession(cwd string) (*Session, error) {
	if err := m.ensureProcess(); err != nil {
		return nil, fmt.Errorf("process: %w", err)
	}

	s := &Session{
		State:  StateCreating,
		proc:   m.proc,
		events: make(chan Event, 256),
		onDone:       make(map[int]func()),
		pendingPerms: make(map[int]*protocol.RPCID),
	}

	tempID := fmt.Sprintf("temp-%d", atomic.AddInt64(&m.nextTemp, 1))

	// Register a temporary handler for routing during creation
	m.proc.RegisterSession(tempID, func(msg *protocol.Message) {
		s.handleMessage(msg)
	})

	m.mu.Lock()
	m.sessions[tempID] = s
	m.mu.Unlock()

	// Send session/new
	id := m.proc.NextID()
	m.proc.TrackResponse(id, func(msg *protocol.Message) {
		if msg.Error != nil {
			s.mu.Lock()
			s.State = StateCompleted
			s.mu.Unlock()
			s.events <- Event{Type: "error", Error: msg.Error.Message}
			close(s.events)
			m.proc.UnregisterSession(tempID)
			m.mu.Lock()
			delete(m.sessions, tempID)
			m.mu.Unlock()
			return
		}

		var result protocol.SessionNewResult
		if err := json.Unmarshal(msg.Result, &result); err != nil {
			s.events <- Event{Type: "error", Error: "bad session/new result"}
			close(s.events)
			return
		}

		s.mu.Lock()
		s.ID = result.SessionID
		s.State = StateActive
		pending := s.pendingUpdates
		s.pendingUpdates = nil
		s.mu.Unlock()

		// Swap routing from temp to real session id
		m.proc.UnregisterSession(tempID)
		m.proc.RegisterSession(s.ID, func(msg *protocol.Message) {
			s.handleMessage(msg)
		})
		m.mu.Lock()
		delete(m.sessions, tempID)
		m.sessions[s.ID] = s
		m.mu.Unlock()

		if result.Models != nil {
			m.proc.SetModels(result.Models)
		}

		s.events <- Event{
			Type:      "session_ready",
			SessionID: s.ID,
			Data:      msg.Result,
		}

		// Replay buffered updates
		for _, pending := range pending {
			s.handleMessage(pending)
		}
	})

	m.mu.Lock()
	servers := m.mcpServers
	m.mu.Unlock()

	log.Printf("acp: sending session/new id=%d cwd=%s", id, cwd)
	req := protocol.SessionNewRequest(id, cwd, servers)
	reqData, _ := json.Marshal(req)
	log.Printf("acp: session/new payload: %s", string(reqData))
	if err := m.proc.Write(req); err != nil {
		return nil, fmt.Errorf("send session/new: %w", err)
	}

	return s, nil
}

// GetSession returns a session by id.
func (m *Manager) GetSession(id string) *Session {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.sessions[id]
}

// ListSessions calls session/list on the ACP process.
func (m *Manager) ListSessions(cwd string) (json.RawMessage, error) {
	if err := m.ensureProcess(); err != nil {
		return nil, err
	}
	id := m.proc.NextID()
	ch := make(chan *protocol.Message, 1)
	m.proc.TrackResponse(id, func(msg *protocol.Message) { ch <- msg })
	if err := m.proc.Write(protocol.SessionListRequest(id, cwd)); err != nil {
		return nil, err
	}
	msg := <-ch
	if msg.Error != nil {
		return nil, fmt.Errorf("%s", msg.Error.Message)
	}
	return msg.Result, nil
}

// LoadSession loads a previous session by ID, returning a Session that streams replayed events.
func (m *Manager) LoadSession(sessionID, cwd string) (*Session, error) {
	if err := m.ensureProcess(); err != nil {
		return nil, err
	}

	s := &Session{
		ID:           sessionID,
		State:        StateActive,
		proc:         m.proc,
		events:       make(chan Event, 256),
		onDone:       make(map[int]func()),
		pendingPerms: make(map[int]*protocol.RPCID),
	}

	m.proc.RegisterSession(sessionID, func(msg *protocol.Message) {
		s.handleMessage(msg)
	})
	m.mu.Lock()
	m.sessions[sessionID] = s
	m.mu.Unlock()

	id := m.proc.NextID()
	m.proc.TrackResponse(id, func(msg *protocol.Message) {
		if msg.Error != nil {
			s.events <- Event{Type: "error", Error: msg.Error.Message}
			return
		}
		// session/load response means replay is done
		s.events <- Event{Type: "session_loaded", SessionID: sessionID}
	})

	m.mu.Lock()
	servers := m.mcpServers
	m.mu.Unlock()

	if err := m.proc.Write(protocol.SessionLoadRequest(id, sessionID, cwd, servers)); err != nil {
		return nil, err
	}
	return s, nil
}

// RemoveSession cleans up a session.
func (m *Manager) RemoveSession(id string) {
	m.mu.Lock()
	delete(m.sessions, id)
	m.mu.Unlock()
	if m.proc != nil {
		m.proc.UnregisterSession(id)
	}
}

// Models returns available models from the process.
func (m *Manager) Models() *protocol.ModelsInfo {
	if m.proc != nil {
		return m.proc.Models()
	}
	return nil
}

// Terminate kills the process and all sessions.
func (m *Manager) Terminate() {
	m.mu.Lock()
	for id, s := range m.sessions {
		s.events <- Event{Type: "terminated"}
		close(s.events)
		delete(m.sessions, id)
	}
	proc := m.proc
	m.proc = nil
	m.mu.Unlock()
	if proc != nil {
		proc.Terminate()
	}
}

// IsHealthy returns true if the process is running.
func (m *Manager) IsHealthy() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.proc != nil
}

// Sessions returns a snapshot of active session IDs.
func (m *Manager) Sessions() []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	ids := make([]string, 0, len(m.sessions))
	for id := range m.sessions {
		ids = append(ids, id)
	}
	return ids
}

// --- Session methods ---

// Events returns the channel for streaming events to the client.
func (s *Session) Events() <-chan Event { return s.events }

// Prompt sends a session/prompt request.
func (s *Session) Prompt(prompt json.RawMessage, onDone func()) error {
	s.mu.Lock()
	s.promptCount++
	s.mu.Unlock()

	id := s.proc.NextID()
	s.mu.Lock()
	s.onDone[id] = onDone
	s.mu.Unlock()

	s.proc.TrackResponse(id, func(msg *protocol.Message) {
		s.handlePromptResponse(id, msg)
	})
	return s.proc.Write(protocol.SessionPromptRequest(id, s.ID, prompt))
}

// SetMode sends session/set_mode.
func (s *Session) SetMode(modeID string) error {
	id := s.proc.NextID()
	s.proc.TrackResponse(id, func(msg *protocol.Message) {
		// ack — nothing to do
	})
	return s.proc.Write(protocol.SessionSetModeRequest(id, s.ID, modeID))
}

// SetModel sends session/set_model.
func (s *Session) SetModel(modelID string) error {
	id := s.proc.NextID()
	s.proc.TrackResponse(id, func(msg *protocol.Message) {
		// ack
	})
	return s.proc.Write(protocol.SessionSetModelRequest(id, s.ID, modelID))
}

// Cancel sends session/cancel.
func (s *Session) Cancel() {
	s.mu.Lock()
	if s.State == StateCancelled || s.State == StateCompleted {
		s.mu.Unlock()
		return
	}
	s.State = StateCancelled
	s.mu.Unlock()
	if s.ID != "" {
		s.proc.Write(protocol.SessionCancelNotification(s.ID))
	}
}

func (s *Session) handleMessage(msg *protocol.Message) {
	s.mu.Lock()
	state := s.State
	s.mu.Unlock()

	// Buffer updates that arrive before session is active
	if state == StateCreating {
		s.mu.Lock()
		s.pendingUpdates = append(s.pendingUpdates, msg)
		s.mu.Unlock()
		return
	}

	if state != StateActive {
		return
	}

	method := msg.Method

	switch method {
	case "session/update":
		s.handleUpdate(msg)
	case "session/request_permission":
		s.handlePermission(msg)
	case "fs/read_text_file":
		s.handleFSRead(msg)
	case "fs/write_text_file":
		s.handleFSWrite(msg)
	default:
		if msg.IsResponse() {
			// Untracked response — ignore
		}
	}
}

func (s *Session) handleUpdate(msg *protocol.Message) {
	var params protocol.SessionUpdateParams
	if err := json.Unmarshal(msg.Params, &params); err != nil {
		return
	}

	var update protocol.SessionUpdate
	if err := json.Unmarshal(params.Update, &update); err != nil {
		// Forward raw update even if we can't parse it
		s.events <- Event{Type: "update", SessionID: s.ID, Data: params.Update}
		return
	}

	switch update.SessionUpdate {
	case "agent_message_chunk":
		if update.Content != nil && update.Content.Type == "text" {
			s.events <- Event{Type: "text", SessionID: s.ID, Text: update.Content.Text}
		}
	case "tool_call":
		title := update.Title
		if title == "" {
			title = update.ToolCallID
		}
		s.events <- Event{Type: "tool_call", SessionID: s.ID, Text: title}
	case "tool_call_update":
		if update.Status == "error" {
			errMsg := update.Message
			if errMsg == "" {
				errMsg = update.Title
			}
			s.events <- Event{Type: "tool_error", SessionID: s.ID, Text: errMsg}
		}
	default:
		s.events <- Event{Type: "update", SessionID: s.ID, Data: params.Update}
	}
}

func (s *Session) handlePermission(msg *protocol.Message) {
	if msg.ID == nil {
		return
	}
	var params protocol.PermissionParams
	if err := json.Unmarshal(msg.Params, &params); err != nil {
		return
	}

	title := ""
	if params.ToolCall != nil {
		title = params.ToolCall.Title
	}

	// Dangerous operations need approval from Lua side
	if strings.HasPrefix(title, "Creating ") ||
		strings.HasPrefix(title, "Deleting ") ||
		(strings.HasPrefix(title, "Running") && strings.Contains(title, "rm ")) {
		s.mu.Lock()
		s.nextPermKey++
		key := s.nextPermKey
		s.pendingPerms[key] = msg.ID
		s.mu.Unlock()
		data, _ := json.Marshal(map[string]any{
			"title":   title,
			"options": params.Options,
			"rpc_id":  key,
		})
		s.events <- Event{Type: "permission_request", SessionID: s.ID, Data: data}
		return
	}

	// Auto-approve safe operations
	optionID := findOption(params.Options, "allow_always", "allow_once")
	if optionID == "" && len(params.Options) > 0 {
		optionID = params.Options[0].OptionID
	}
	s.proc.Write(protocol.PermissionResponse(msg.ID, optionID))
	s.events <- Event{Type: "permission_auto", SessionID: s.ID, Text: title}
}

func (s *Session) handleFSRead(msg *protocol.Message) {
	if msg.ID == nil {
		return
	}
	var params protocol.FSReadParams
	if err := json.Unmarshal(msg.Params, &params); err != nil {
		return
	}

	content, err := os.ReadFile(params.Path)
	if err != nil {
		content = []byte{}
	}

	s.events <- Event{Type: "fs_read", SessionID: s.ID, Text: params.Path}
	s.proc.Write(protocol.FSReadResponse(msg.ID, string(content)))
}

func (s *Session) handleFSWrite(msg *protocol.Message) {
	if msg.ID == nil {
		return
	}
	var params protocol.FSWriteParams
	if err := json.Unmarshal(msg.Params, &params); err != nil {
		return
	}

	if err := os.WriteFile(params.Path, []byte(params.Content), 0644); err != nil {
		log.Printf("acp: write %s: %v", params.Path, err)
	}

	s.proc.Write(protocol.FSWriteResponse(msg.ID))
	s.events <- Event{Type: "fs_write", SessionID: s.ID, Text: params.Path}
}

func (s *Session) handlePromptResponse(rpcID int, msg *protocol.Message) {
	if msg.Error != nil {
		s.events <- Event{Type: "prompt_error", SessionID: s.ID, Error: msg.Error.Message}
		return
	}

	s.events <- Event{Type: "prompt_done", SessionID: s.ID}

	s.mu.Lock()
	cb := s.onDone[rpcID]
	delete(s.onDone, rpcID)
	s.mu.Unlock()
	if cb != nil {
		cb()
	}
}

// RespondPermission sends a permission response (called by Lua after user choice).
func (s *Session) RespondPermission(rpcID int, optionID string) {
	s.mu.Lock()
	origID := s.pendingPerms[rpcID]
	delete(s.pendingPerms, rpcID)
	s.mu.Unlock()
	if origID != nil {
		s.proc.Write(protocol.PermissionResponse(origID, optionID))
	}
}

func findOption(opts []protocol.PermissionOption, kinds ...string) string {
	for _, kind := range kinds {
		for _, o := range opts {
			if o.Kind == kind {
				return o.OptionID
			}
		}
	}
	return ""
}
