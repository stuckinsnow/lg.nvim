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
		State:          StateCreating,
		proc:           proc,
		events:         make(chan Event, 256),
		onDone:         make(map[int]func()),
		pendingPerms:   make(map[int]*protocol.RPCID),
		approvedDirs:   make(map[string]bool),
		pendingPermDir: make(map[int]string),
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
func (s *Session) ExecuteCommand(command string, args map[string]any, onDone func(msg *protocol.Message)) error {
	id := s.proc.NextID()
	s.proc.TrackResponse(id, onDone)
	return s.proc.Write(protocol.CommandExecuteRequest(id, s.ID, command, args))
}

// RPCCall sends an arbitrary JSON-RPC request and tracks the response.
// Used for non-standard methods like _kiro.dev/commands/model/options.
func (s *Session) RPCCall(method string, params map[string]any, onDone func(msg *protocol.Message)) error {
	id := s.proc.NextID()
	s.proc.TrackResponse(id, onDone)
	return s.proc.Write(protocol.GenericRequest(id, method, params))
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
	dir := s.pendingPermDir[rpcID]
	delete(s.pendingPermDir, rpcID)
	s.mu.Unlock()
	if origID != nil {
		s.proc.Write(protocol.PermissionResponse(origID, optionID))
		// If user approved a read-only outside-cwd op, remember the dir
		if dir != "" && (optionID == "allow_once" || optionID == "allow_always") {
			s.mu.Lock()
			s.approvedDirs[dir] = true
			s.mu.Unlock()
			log.Printf("acp: approved dir for session: %s", dir)
		}
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
			MeteringUsage          []struct {
				Value      float64 `json:"value"`
				Unit       string  `json:"unit"`
				UnitPlural string  `json:"unitPlural"`
			} `json:"meteringUsage"`
			TurnDurationMs int64 `json:"turnDurationMs"`
		}
		if json.Unmarshal(msg.Params, &params) == nil {
			data, _ := json.Marshal(map[string]any{"context_pct": params.ContextUsagePercentage})
			s.events <- Event{Type: "context_usage", SessionID: s.ID, Data: data}

			if len(params.MeteringUsage) > 0 || params.TurnDurationMs > 0 {
				var total float64
				unit := "credits"
				for _, m := range params.MeteringUsage {
					total += m.Value
					if m.UnitPlural != "" {
						unit = m.UnitPlural
					} else if m.Unit != "" {
						unit = m.Unit
					}
				}
				mdata, _ := json.Marshal(map[string]any{
					"total":            total,
					"unit":             unit,
					"turn_duration_ms": params.TurnDurationMs,
					"entries":          len(params.MeteringUsage),
				})
				s.events <- Event{Type: "metering", SessionID: s.ID, Data: mdata}
			}
		}
	case "_kiro.dev/compaction/status":
		s.events <- Event{Type: "compaction", SessionID: s.ID, Data: msg.Params}
	case "_kiro.dev/commands/available":
		s.events <- Event{Type: "commands_available", SessionID: s.ID, Data: msg.Params}
	case "_kiro.dev/clear/status":
		s.events <- Event{Type: "clear_status", SessionID: s.ID, Data: msg.Params}
	case "_kiro.dev/agent/switched":
		s.events <- Event{Type: "agent_switched", SessionID: s.ID, Data: msg.Params}
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

	// Check access guard on file-related permissions
	if s.Guard != nil {
		p := ExtractPathFromTitle(title)
		if p == "" && isFileOperation(title) {
			// Title gave a relative path — try _meta.trustOptions for the real one
			p = ExtractPathFromMeta(params.Meta)
		}
		if p != "" {
			log.Printf("acp: guard check title=%q path=%q", title, p)
			if reason := s.Guard.CheckAccess(p); reason != "" {
				// Outside CWD — but if it's read-only, check approved dirs
				if isReadOnlyFileOp(title) && reason == "blocked: outside project directory" {
					s.mu.Lock()
					approved := s.approvedDirs[p]
					if !approved {
						// Check if any parent dir was approved
						for dir := range s.approvedDirs {
							if strings.HasPrefix(p, dir+"/") || p == dir {
								approved = true
								break
							}
						}
					}
					s.mu.Unlock()
					if approved {
						optionID := findOption(params.Options, "allow_always", "allow_once")
						if optionID == "" && len(params.Options) > 0 {
							optionID = params.Options[0].OptionID
						}
						s.proc.Write(protocol.PermissionResponse(msg.ID, optionID))
						s.events <- Event{Type: "permission_auto", SessionID: s.ID, Text: title}
						return
					}
					// First time seeing this dir — ask user, remember path for approval
					log.Printf("acp: outside-cwd read op, requesting approval: %s (path=%s)", title, p)
					s.mu.Lock()
					s.nextPermKey++
					key := s.nextPermKey
					s.pendingPerms[key] = msg.ID
					s.pendingPermDir[key] = p
					s.mu.Unlock()
					data, _ := json.Marshal(map[string]any{
						"title":   title,
						"options": params.Options,
						"rpc_id":  key,
						"_dir":    p,
					})
					s.events <- Event{Type: "permission_request", SessionID: s.ID, Data: data}
					return
				}
				log.Printf("acp: permission denied %s (%s)", title, reason)
				optionID := findOption(params.Options, "reject_once", "reject_always")
				if optionID == "" && len(params.Options) > 0 {
					optionID = params.Options[len(params.Options)-1].OptionID
				}
				s.proc.Write(protocol.PermissionResponse(msg.ID, optionID))
				s.events <- Event{Type: "permission_denied", SessionID: s.ID, Text: title + " — " + reason}
				return
			}
		} else if isFileOperation(title) {
			// Can't extract path from title or _meta — route through manual approval.
			log.Printf("acp: unverifiable file op, requesting approval: %s", title)
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
	}

	// Dangerous operations need approval from Lua side
	needsApproval := strings.HasPrefix(title, "Creating ") ||
		strings.HasPrefix(title, "Deleting ") ||
		(strings.HasPrefix(title, "Running") && !strings.Contains(title, "@lg/") && !strings.Contains(title, "@lg-hint/")) ||
		strings.Contains(strings.ToLower(title), "devlens")

	if needsApproval {
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

	if s.Guard != nil {
		if reason := s.Guard.CheckAccess(params.Path); reason != "" {
			log.Printf("acp: fs_read denied %s (%s)", params.Path, reason)
			s.events <- Event{Type: "fs_read_denied", SessionID: s.ID, Text: params.Path + " — " + reason}
			s.proc.Write(protocol.FSReadResponse(msg.ID, ""))
			return
		}
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

	if s.Guard != nil {
		if reason := s.Guard.CheckAccess(params.Path); reason != "" {
			log.Printf("acp: fs_write denied %s (%s)", params.Path, reason)
			s.events <- Event{Type: "fs_write_denied", SessionID: s.ID, Text: params.Path + " — " + reason}
			s.proc.Write(protocol.FSWriteResponse(msg.ID))
			return
		}
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
