package session

import (
	"encoding/json"
	"fmt"
	"lg-acp/internal/process"
	"lg-acp/internal/protocol"
	"log"
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

// sessionMCPServers returns MCP servers in the shape the agent expects.
// antigravity follows the ACP spec (an array); kiro and opencode keep the map
// lg has always sent them.
func (m *Manager) sessionMCPServers() any {
	m.mu.Lock()
	servers := m.mcpServers
	m.mu.Unlock()
	if m.proc != nil && m.proc.Isantigravity() {
		return protocol.ACPMCPServers(servers)
	}
	return servers
}

// ensureProcess spawns the ACP subprocess if not already running.
func (m *Manager) ensureProcess() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.proc != nil {
		return nil
	}
	proc, err := process.Spawn(m.cmd, m.clientName, m.handleAgentError)
	if err != nil {
		return err
	}
	m.proc = proc
	return nil
}

// handleAgentError forwards an error the agent logged on stderr to its session.
func (m *Manager) handleAgentError(sessionID, msg string) {
	if s := m.GetSession(sessionID); s != nil {
		s.agentError(msg)
	}
}

// CreateSession creates a new ACP session and returns it.
// The session's Events channel streams updates back to the caller.
func (m *Manager) CreateSession(cwd string) (*Session, error) {
	if err := m.ensureProcess(); err != nil {
		return nil, fmt.Errorf("process: %w", err)
	}

	s := newSession(m.proc, StateCreating, "", cwd)
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
		s.mode = result.Modes.CurrentModeID
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

		if mi := protocol.ParseModelsInfo(msg.Result); mi != nil {
			m.proc.SetModels(mi)
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

	servers := m.sessionMCPServers()

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

// call sends a request on the shared process and waits for its response.
func (m *Manager) call(method string, params map[string]any) (json.RawMessage, error) {
	if err := m.ensureProcess(); err != nil {
		return nil, err
	}
	id := m.proc.NextID()
	ch := make(chan *protocol.Message, 1)
	m.proc.TrackResponse(id, func(msg *protocol.Message) { ch <- msg })
	if err := m.proc.Write(protocol.GenericRequest(id, method, params)); err != nil {
		return nil, err
	}
	select {
	case msg := <-ch:
		if msg.Error != nil {
			return nil, fmt.Errorf("%s", msg.Error.Detail())
		}
		return msg.Result, nil
	case <-time.After(30 * time.Second):
		return nil, fmt.Errorf("%s: timeout", method)
	}
}

// ListSessions calls session/list on the ACP process.
func (m *Manager) ListSessions(cwd string) (json.RawMessage, error) {
	return m.call("session/list", map[string]any{"cwd": cwd})
}

// DeleteSession deletes a saved session through kiro's _kiro/session/delete.
func (m *Manager) DeleteSession(sessionID string) error {
	if err := m.ensureProcess(); err != nil {
		return err
	}
	if !m.proc.IsKiro() {
		return fmt.Errorf("deleting sessions isn't supported by this provider")
	}
	_, err := m.call("_kiro/session/delete", map[string]any{"sessionId": sessionID})
	return err
}

// LoadSession loads a previous session by ID, returning a Session that streams replayed events.
func (m *Manager) LoadSession(sessionID, cwd string) (*Session, error) {
	if err := m.ensureProcess(); err != nil {
		return nil, err
	}

	// Kiro returns models from session/load; other agents (opencode) only
	// report them on session/new, so fetch them with a throwaway session.
	if !m.proc.IsKiro() && m.proc.Models() == nil {
		m.fetchModels(cwd)
	}

	s := newSession(m.proc, StateActive, sessionID, cwd)

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
		var result struct {
			Meta struct {
				AgentMode    string `json:"agentMode"`
				ContextUsage *struct {
					UsagePercentage float64 `json:"usagePercentage"`
				} `json:"contextUsage"`
			} `json:"_meta"`
		}
		json.Unmarshal(msg.Result, &result)
		if mi := protocol.ParseModelsInfo(msg.Result); mi != nil {
			m.proc.SetModels(mi)
		}
		s.setMode(result.Meta.AgentMode)
		s.events <- Event{Type: "session_loaded", SessionID: sessionID}
		if cu := result.Meta.ContextUsage; cu != nil {
			s.emit("context_usage", map[string]any{"context_pct": cu.UsagePercentage})
		}
	})

	servers := m.sessionMCPServers()

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

// fetchModels creates a throwaway session to populate models info, for agents
// that only report models on session/new.
func (m *Manager) fetchModels(cwd string) {
	done := make(chan struct{})
	id := m.proc.NextID()

	m.proc.TrackResponse(id, func(msg *protocol.Message) {
		defer close(done)
		if msg.Error != nil || msg.Result == nil {
			return
		}
		if mi := protocol.ParseModelsInfo(msg.Result); mi != nil && len(mi.AvailableModels) > 0 {
			m.proc.SetModels(mi)
		}
	})

	servers := m.sessionMCPServers()

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
