package session

import (
	"encoding/json"
	"lg-acp/internal/process"
	"lg-acp/internal/protocol"
	"log"
	"os"
	"strings"
)

func newSession(proc *process.Process) *Session {
	return &Session{
		State:        StateCreating,
		proc:         proc,
		events:       make(chan Event, 256),
		onDone:       make(map[int]func()),
		pendingPerms: make(map[int]*protocol.RPCID),
	}
}

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
	s.proc.TrackResponse(id, func(msg *protocol.Message) {})
	return s.proc.Write(protocol.SessionSetModeRequest(id, s.ID, modeID))
}

// SetModel sends session/set_model.
func (s *Session) SetModel(modelID string) error {
	id := s.proc.NextID()
	s.proc.TrackResponse(id, func(msg *protocol.Message) {})
	return s.proc.Write(protocol.SessionSetModelRequest(id, s.ID, modelID))
}

// ExecuteCommand sends _kiro.dev/commands/execute.
func (s *Session) ExecuteCommand(command string, onDone func(msg *protocol.Message)) error {
	id := s.proc.NextID()
	s.proc.TrackResponse(id, onDone)
	return s.proc.Write(protocol.CommandExecuteRequest(id, s.ID, command))
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

// --- internal message handling ---

func (s *Session) handleMessage(msg *protocol.Message) {
	s.mu.Lock()
	state := s.State
	s.mu.Unlock()

	if state == StateCreating {
		s.mu.Lock()
		s.pendingUpdates = append(s.pendingUpdates, msg)
		s.mu.Unlock()
		return
	}
	if state != StateActive {
		return
	}

	switch msg.Method {
	case "session/update":
		s.handleUpdate(msg)
	case "session/request_permission":
		s.handlePermission(msg)
	case "fs/read_text_file":
		s.handleFSRead(msg)
	case "fs/write_text_file":
		s.handleFSWrite(msg)
	case "_kiro.dev/metadata":
		var params struct {
			SessionID              string  `json:"sessionId"`
			ContextUsagePercentage float64 `json:"contextUsagePercentage"`
		}
		if json.Unmarshal(msg.Params, &params) == nil {
			data, _ := json.Marshal(map[string]any{"context_pct": params.ContextUsagePercentage})
			s.events <- Event{Type: "context_usage", SessionID: s.ID, Data: data}
		}
	case "_kiro.dev/compaction/status":
		s.events <- Event{Type: "compaction", SessionID: s.ID, Data: msg.Params}
	case "_kiro.dev/commands/available":
		s.events <- Event{Type: "commands_available", SessionID: s.ID, Data: msg.Params}
	case "_kiro.dev/clear/status":
		s.events <- Event{Type: "clear_status", SessionID: s.ID, Data: msg.Params}
	}
}

func (s *Session) handleUpdate(msg *protocol.Message) {
	var params protocol.SessionUpdateParams
	if err := json.Unmarshal(msg.Params, &params); err != nil {
		return
	}

	var update protocol.SessionUpdate
	if err := json.Unmarshal(params.Update, &update); err != nil {
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
		(strings.HasPrefix(title, "Running") && strings.Contains(title, "rm ")) ||
		strings.Contains(strings.ToLower(title), "devlens") {
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
