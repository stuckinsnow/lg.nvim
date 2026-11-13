package session

import (
	"encoding/json"
	"lg-acp/internal/process"
	"lg-acp/internal/protocol"
	"log"
	"os"
	"path/filepath"
	"strings"
)

func newSession(proc *process.Process, state State, id, cwd string) *Session {
	return &Session{
		ID:             id,
		State:          state,
		proc:           proc,
		Guard:          NewAccessGuard(cwd),
		events:         make(chan Event, 256),
		onDone:         make(map[int]func()),
		pendingPerms:   make(map[int]*protocol.RPCID),
		approvedDirs:   make(map[string]bool),
		pendingPermDir: make(map[int]string),
		pendingPermOpt: make(map[int][]protocol.PermissionOption),
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

// SetModel switches the session model. Kiro v3 only accepts the model as a
// config option; other agents use session/set_model.
func (s *Session) SetModel(modelID string) error {
	id := s.proc.NextID()
	s.proc.TrackResponse(id, func(msg *protocol.Message) {})
	if s.proc.IsKiro() {
		return s.proc.Write(protocol.SessionSetConfigOptionRequest(id, s.ID, "model", modelID))
	}
	return s.proc.Write(protocol.SessionSetModelRequest(id, s.ID, modelID))
}

// RPCCall sends an arbitrary JSON-RPC request and tracks the response.
// Used for kiro extension methods like _kiro/session/compact.
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
	dir := s.pendingPermDir[rpcID]
	opts := s.pendingPermOpt[rpcID]
	delete(s.pendingPerms, rpcID)
	delete(s.pendingPermDir, rpcID)
	delete(s.pendingPermOpt, rpcID)
	s.mu.Unlock()
	if origID == nil {
		return
	}
	s.proc.Write(protocol.PermissionResponse(origID, optionID))
	// If user approved a read-only outside-cwd op, remember the dir
	if dir != "" && isAllow(opts, optionID) {
		s.mu.Lock()
		s.approvedDirs[dir] = true
		s.mu.Unlock()
		log.Printf("acp: approved dir for session: %s", dir)
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
	default:
		// Never leave an agent-to-client request unanswered: the agent would wait forever.
		if msg.IsRequest() {
			s.proc.Write(protocol.MethodNotFoundResponse(msg.ID, msg.Method))
		}
	}
}

func (s *Session) emit(typ string, data any) {
	raw, _ := json.Marshal(data)
	s.events <- Event{Type: typ, SessionID: s.ID, Data: raw}
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
		if update.Status == "failed" || update.Status == "error" {
			errMsg := update.Message
			if errMsg == "" {
				errMsg = update.Title
			}
			if reason := update.Meta.Kiro.FailureReason; reason != "" && errMsg != "" {
				errMsg += " (" + reason + ")"
			}
			s.events <- Event{Type: "tool_error", SessionID: s.ID, Text: errMsg}
		}
	case "current_mode_update":
		s.setMode(update.CurrentModeID)
	case "config_option_update":
		for _, co := range update.ConfigOptions {
			if co.ID == "mode" {
				s.setMode(co.CurrentValue)
			}
		}
	case "available_commands_update":
		cmds := make([]map[string]string, 0, len(update.AvailableCommands))
		for _, c := range update.AvailableCommands {
			cmds = append(cmds, map[string]string{"name": c.Name})
		}
		s.emit("commands_available", map[string]any{"commands": cmds})
	case "session_info_update":
		s.handleInfoUpdate(update.Meta.Kiro)
	default:
		s.events <- Event{Type: "update", SessionID: s.ID, Data: params.Update}
	}
}

// handleInfoUpdate maps kiro's session_info_update kinds onto lg's events.
func (s *Session) handleInfoUpdate(k protocol.KiroUpdateMeta) {
	if k.ContextUsage != nil {
		s.emit("context_usage", map[string]any{"context_pct": k.ContextUsage.UsagePercentage})
	}
	switch k.Kind {
	case "turn_completion":
		if k.Replay {
			return
		}
		var total float64
		unit := "credits"
		for _, m := range k.PromptTurnSummaries {
			total += m.Usage
			if m.UnitPlural != "" {
				unit = m.UnitPlural
			} else if m.Unit != "" {
				unit = m.Unit
			}
		}
		s.emit("metering", map[string]any{
			"total":            total,
			"unit":             unit,
			"turn_duration_ms": k.ElapsedTime,
			"entries":          len(k.PromptTurnSummaries),
		})
	case "summarization_started":
		s.emit("compaction", map[string]any{"status": "started"})
	}
}

// setMode records the agent mode and reports real switches. The first mode
// seen after a load is recorded silently, since nothing switched.
func (s *Session) setMode(mode string) {
	if mode == "" {
		return
	}
	s.mu.Lock()
	prev := s.mode
	s.mode = mode
	s.mu.Unlock()
	if prev != "" && prev != mode {
		s.emit("agent_switched", map[string]string{"agentName": mode, "previousAgentName": prev})
	}
}

// --- permissions ---

func (s *Session) allow(id *protocol.RPCID, opts []protocol.PermissionOption, title string) {
	// Prefer allow_once: on kiro v3, allow_always writes a persistent rule.
	optionID := findOption(opts, "allow_once", "allow_always")
	if optionID == "" && len(opts) > 0 {
		optionID = opts[0].OptionID
	}
	s.proc.Write(protocol.PermissionResponse(id, optionID))
	s.events <- Event{Type: "permission_auto", SessionID: s.ID, Text: title}
}

func (s *Session) deny(id *protocol.RPCID, opts []protocol.PermissionOption, title, reason string) {
	log.Printf("acp: permission denied %s (%s)", title, reason)
	optionID := findOption(opts, "reject_once", "reject_always")
	if optionID == "" && len(opts) > 0 {
		optionID = opts[len(opts)-1].OptionID
	}
	s.proc.Write(protocol.PermissionResponse(id, optionID))
	s.events <- Event{Type: "permission_denied", SessionID: s.ID, Text: title + " — " + reason}
}

// ask forwards the request to Lua. dir, when set, is remembered as approved
// for reads if the user allows it.
func (s *Session) ask(id *protocol.RPCID, opts []protocol.PermissionOption, title, dir string) {
	s.mu.Lock()
	s.nextPermKey++
	key := s.nextPermKey
	s.pendingPerms[key] = id
	s.pendingPermOpt[key] = opts
	if dir != "" {
		s.pendingPermDir[key] = dir
	}
	s.mu.Unlock()
	data := map[string]any{"title": title, "options": opts, "rpc_id": key}
	if dir != "" {
		data["_dir"] = dir
	}
	s.emit("permission_request", data)
}

func (s *Session) dirApproved(p string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.approvedDirs[p] {
		return true
	}
	for dir := range s.approvedDirs {
		if strings.HasPrefix(p, dir+"/") {
			return true
		}
	}
	return false
}

func (s *Session) handlePermission(msg *protocol.Message) {
	if msg.ID == nil {
		return
	}
	var params protocol.PermissionParams
	if err := json.Unmarshal(msg.Params, &params); err != nil {
		return
	}
	if params.Meta != nil && params.Meta.Kiro.Consent != nil {
		s.handleConsent(msg.ID, params)
		return
	}
	s.handleTitlePermission(msg.ID, params)
}

// handleConsent decides kiro v3 permission requests from _meta.kiro.consent.
func (s *Session) handleConsent(id *protocol.RPCID, params protocol.PermissionParams) {
	c := params.Meta.Kiro.Consent
	opts := params.Options

	switch c.Capability {
	case "fs_read", "fs_write":
		p := c.Resource
		if !filepath.IsAbs(p) {
			root := c.WorkspaceRoot
			if root == "" {
				root = s.Guard.cwd
			}
			p = filepath.Join(root, p)
		}
		read := c.Capability == "fs_read"
		title := "Write " + p
		if read {
			title = "Read " + p
		}
		reason := s.Guard.CheckAccess(p)
		switch {
		case reason == "" && read:
			s.allow(id, opts, title)
		case reason == "":
			s.ask(id, opts, title, "")
		case read && reason == reasonOutsideCWD && s.dirApproved(p):
			s.allow(id, opts, title)
		case read && reason == reasonOutsideCWD:
			s.ask(id, opts, title, p)
		default:
			s.deny(id, opts, title, reason)
		}
	case "shell":
		s.ask(id, opts, "Run: "+c.Resource, "")
	case "mcp":
		server, _, _ := strings.Cut(c.Resource, "/")
		title := "@" + c.Resource
		if server == "lg" || server == "lg-hint" {
			s.allow(id, opts, title)
		} else {
			s.ask(id, opts, title, "")
		}
	default:
		title := c.Capability
		if c.Resource != "" {
			title += ": " + c.Resource
		}
		s.allow(id, opts, title)
	}
}

// handleTitlePermission decides permission requests that carry no consent
// metadata (opencode), based on the tool title.
func (s *Session) handleTitlePermission(id *protocol.RPCID, params protocol.PermissionParams) {
	title := ""
	if params.ToolCall != nil {
		title = params.ToolCall.Title
	}
	opts := params.Options

	// Check access guard on file-related permissions
	if s.Guard != nil {
		if p := ExtractPathFromTitle(title); p != "" {
			log.Printf("acp: guard check title=%q path=%q", title, p)
			if reason := s.Guard.CheckAccess(p); reason != "" {
				// Outside CWD — but if it's read-only, check approved dirs
				if isReadOnlyFileOp(title) && reason == reasonOutsideCWD {
					if s.dirApproved(p) {
						s.allow(id, opts, title)
					} else {
						log.Printf("acp: outside-cwd read op, requesting approval: %s (path=%s)", title, p)
						s.ask(id, opts, title, p)
					}
					return
				}
				s.deny(id, opts, title, reason)
				return
			}
		} else if isFileOperation(title) {
			// Can't extract a verifiable path — route through manual approval.
			log.Printf("acp: unverifiable file op, requesting approval: %s", title)
			s.ask(id, opts, title, "")
			return
		}
	}

	// Dangerous operations need approval from Lua side
	needsApproval := strings.HasPrefix(title, "Creating ") ||
		strings.HasPrefix(title, "Deleting ") ||
		(strings.HasPrefix(title, "Running") && !strings.Contains(title, "@lg/") && !strings.Contains(title, "@lg-hint/")) ||
		strings.Contains(strings.ToLower(title), "devlens")
	if needsApproval {
		s.ask(id, opts, title, "")
		return
	}
	s.allow(id, opts, title)
}

// --- fs ---

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
	s.proc.Write(protocol.FSReadResponse(msg.ID, sliceLines(string(content), params.Line, params.Limit)))
}

// sliceLines returns `limit` lines starting at 1-based `line`. Zero values mean
// "from the start" and "to the end".
func sliceLines(content string, line, limit int) string {
	if line <= 1 && limit <= 0 {
		return content
	}
	lines := strings.SplitAfter(content, "\n")
	start := max(line-1, 0)
	if start >= len(lines) {
		return ""
	}
	end := len(lines)
	if limit > 0 && start+limit < end {
		end = start + limit
	}
	return strings.Join(lines[start:end], "")
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
		// Drop the pending onDone: the turn will never complete, and leaving it
		// behind leaks the callback for the lifetime of the session.
		s.mu.Lock()
		delete(s.onDone, rpcID)
		s.mu.Unlock()
		detail := msg.Error.Detail()
		log.Printf("acp: prompt error: %s", detail)
		s.events <- Event{Type: "prompt_error", SessionID: s.ID, Error: detail}
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

// isAllow reports whether optionID is one of the allow options.
func isAllow(opts []protocol.PermissionOption, optionID string) bool {
	for _, o := range opts {
		if o.OptionID == optionID {
			return o.Kind == "allow_once" || o.Kind == "allow_always"
		}
	}
	return false
}
