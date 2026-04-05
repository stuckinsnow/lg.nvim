package session

import (
	"encoding/json"
	"fmt"
	"lg-acp/internal/process"
	"lg-acp/internal/protocol"
	"log"
	"os"
	"path/filepath"
	"sync/atomic"
	"time"
)

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

	s := newSession(m.proc)
	s.Guard = NewAccessGuard(cwd)
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

	// Fetch models via a throwaway session/new if we don't have them yet
	if m.proc.Models() == nil {
		m.fetchModels(cwd)
	}

	s := &Session{
		ID:           sessionID,
		State:        StateActive,
		proc:         m.proc,
		Guard:        NewAccessGuard(cwd),
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
		s.events <- Event{Type: "session_loaded", SessionID: sessionID}
		// Emit last known context usage from the session file
		if pct := readKiroContextPct(sessionID); pct > 0 {
			data, _ := json.Marshal(map[string]any{"context_pct": pct})
			s.events <- Event{Type: "context_usage", SessionID: sessionID, Data: data}
		}
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

// fetchModels creates a throwaway session to populate models info.
func (m *Manager) fetchModels(cwd string) {
	done := make(chan struct{})
	id := m.proc.NextID()

	m.proc.TrackResponse(id, func(msg *protocol.Message) {
		defer close(done)
		if msg.Error != nil || msg.Result == nil {
			return
		}
		var result struct {
			Models *protocol.ModelsInfo `json:"models"`
		}
		if json.Unmarshal(msg.Result, &result) == nil && result.Models != nil {
			m.proc.SetModels(result.Models)
		}
	})

	m.mu.Lock()
	servers := m.mcpServers
	m.mu.Unlock()

	m.proc.Write(protocol.SessionNewRequest(id, cwd, servers))

	select {
	case <-done:
	case <-time.After(10 * time.Second):
		log.Printf("acp: fetchModels timeout")
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

// readKiroContextPct reads the last context_usage_percentage from a kiro session file.
func readKiroContextPct(sessionID string) float64 {
	home, err := os.UserHomeDir()
	if err != nil {
		return 0
	}
	data, err := os.ReadFile(filepath.Join(home, ".kiro", "sessions", "cli", sessionID+".json"))
	if err != nil {
		return 0
	}
	var f struct {
		State struct {
			Conv struct {
				Turns []struct {
					ContextPct float64 `json:"context_usage_percentage"`
				} `json:"user_turn_metadatas"`
			} `json:"conversation_metadata"`
		} `json:"session_state"`
	}
	if json.Unmarshal(data, &f) != nil {
		return 0
	}
	turns := f.State.Conv.Turns
	if len(turns) == 0 {
		return 0
	}
	return turns[len(turns)-1].ContextPct
}
