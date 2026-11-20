package session

import (
	"encoding/json"
	"lg-acp/internal/process"
	"lg-acp/internal/protocol"
	"log"
	"os"
	"strconv"
	"strings"
	"time"
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

	started := time.Now()
	s.proc.TrackResponse(id, func(msg *protocol.Message) {
		s.handlePromptResponse(id, msg, started)
	})
	return s.proc.Write(protocol.SessionPromptRequest(id, s.ID, prompt))
}

// SetMode sends session/set_mode.
func (s *Session) SetMode(modeID string) error {
	id := s.proc.NextID()
	s.proc.TrackResponse(id, func(msg *protocol.Message) {})
	return s.proc.Write(protocol.SessionSetModeRequest(id, s.ID, modeID))
}

// SetModel switches the session model via the "model" config option. Kiro v3
// and opencode 2.x only accept this; opencode 2.x removed session/set_model.
func (s *Session) SetModel(modelID string, onDone func(*protocol.Message)) error {
	id := s.proc.NextID()
	s.proc.TrackResponse(id, onDone)
	return s.proc.Write(protocol.SessionSetConfigOptionRequest(id, s.ID, "model", modelID))
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

// agentError reports an error the agent logged on stderr without answering
// the prompt. The turn may still finish (agents can retry), so Lua decides
// whether to wait or abort.
func (s *Session) agentError(msg string) {
	s.mu.Lock()
	inFlight := len(s.onDone) > 0
	s.mu.Unlock()
	if inFlight {
		s.events <- Event{Type: "agent_error", SessionID: s.ID, Error: msg}
	}
}

// AbortPrompt ends the in-flight turn as failed with reason, for agents that
// errored without answering session/prompt. The session stays usable: a late
// response to the aborted prompt is ignored.
func (s *Session) AbortPrompt(reason string) {
	s.mu.Lock()
	if len(s.onDone) == 0 {
		s.mu.Unlock()
		return
	}
	clear(s.onDone)
	s.mu.Unlock()
	if s.ID != "" {
		s.proc.Write(protocol.SessionCancelNotification(s.ID))
	}
	s.events <- Event{Type: "prompt_error", SessionID: s.ID, Error: reason}
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
		cwd := ""
		if s.Guard != nil {
			cwd = s.Guard.cwd
		}
		s.events <- Event{Type: "tool_call", SessionID: s.ID, Text: formatToolCall(update, cwd)}
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
		modelOption := false
		for _, co := range update.ConfigOptions {
			if co.ID == "mode" {
				s.setMode(co.CurrentValue)
			}
		}
		if modelID := changedModel(update); modelID != "" {
			s.events <- Event{Type: "model_changed", SessionID: s.ID, Text: modelID}
		}
		for _, option := range update.ConfigOptions {
			if option.ID == "model" {
				modelOption = true
				break
			}
		}
		if modelOption {
			// A provider can advertise a model after session/new. Forward the
			// complete config update so clients can retry a pending selection.
			s.emit("models_updated", params.Update)
		}
		if mi := protocol.ParseModelsInfo(params.Update); mi != nil && len(mi.AvailableModels) > 0 {
			s.proc.ReplaceModels(mi)
		}
	case "available_commands_update":
		cmds := make([]map[string]string, 0, len(update.AvailableCommands))
		for _, c := range update.AvailableCommands {
			cmds = append(cmds, map[string]string{"name": c.Name})
		}
		s.emit("commands_available", map[string]any{"commands": cmds})
	case "usage_update":
		data := map[string]any{}
		if update.Used != nil {
			data["used"] = *update.Used
		}
		if update.Size != nil {
			data["size"] = *update.Size
			if *update.Size > 0 && update.Used != nil {
				data["context_pct"] = float64(*update.Used) / float64(*update.Size) * 100
			}
		}
		s.emit("context_usage", data)
	case "session_info_update":
		s.handleInfoUpdate(update.Meta.Kiro)
	default:
		s.events <- Event{Type: "update", SessionID: s.ID, Data: params.Update}
	}
}

// formatToolCall builds a concise label for an ACP tool_call update. When the
// agent only sends a generic title (e.g. "Run mcp_lg_read_buffer"), it appends
// the target path and line range from rawInput or locations.
func formatToolCall(update protocol.SessionUpdate, cwd string) string {
	title := update.Title
	if title == "" {
		title = update.ToolCallID
	}
	title = strings.ReplaceAll(title, "lg_lg_", "lg_")
	detail := toolCallDetail(update, cwd)
	if detail == "" || strings.Contains(title, detail) {
		return title
	}
	return title + " " + detail
}

func toolCallDetail(update protocol.SessionUpdate, cwd string) string {
	if len(update.RawInput) > 0 {
		var in struct {
			Path      string `json:"path"`
			File      string `json:"file"`
			FilePath  string `json:"file_path"`
			StartLine int    `json:"start_line"`
			EndLine   int    `json:"end_line"`
			Pattern   string `json:"pattern"`
			Command   string `json:"command"`
		}
		if json.Unmarshal(update.RawInput, &in) == nil {
			if in.Command != "" {
				return in.Command
			}
			p := in.Path
			if p == "" {
				p = in.File
			}
			if p == "" {
				p = in.FilePath
			}
			if p != "" {
				p = trimCWD(p, cwd)
				if in.StartLine > 0 && in.EndLine > 0 {
					return p + ":" + strconv.Itoa(in.StartLine) + "-" + strconv.Itoa(in.EndLine)
				}
				if in.StartLine > 0 {
					return p + ":" + strconv.Itoa(in.StartLine)
				}
				return p
			}
			if in.Pattern != "" {
				return in.Pattern
			}
		}
	}
	if len(update.Locations) > 0 && update.Locations[0].Path != "" {
		p := trimCWD(update.Locations[0].Path, cwd)
		if update.Locations[0].Line > 0 {
			return p + ":" + strconv.Itoa(update.Locations[0].Line)
		}
		return p
	}
	return ""
}

func trimCWD(p, cwd string) string {
	if cwd == "" {
		return p
	}
	prefix := strings.TrimRight(cwd, "/") + "/"
	return strings.TrimPrefix(p, prefix)
}

// changedModel returns the model confirmed by a config update, if present.
// Keeping this extraction separate makes the event contract easy to test
// without starting a provider process.
func changedModel(update protocol.SessionUpdate) string {
	for _, option := range update.ConfigOptions {
		if option.ID == "model" {
			return option.CurrentValue
		}
	}
	return ""
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

func (s *Session) handlePromptResponse(rpcID int, msg *protocol.Message, started time.Time) {
	s.mu.Lock()
	_, pending := s.onDone[rpcID]
	s.mu.Unlock()
	if !pending {
		return // aborted turn; Lua already got prompt_error for it
	}
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

	var res protocol.PromptResult
	if len(msg.Result) > 0 && json.Unmarshal(msg.Result, &res) == nil && res.Usage != nil && res.Usage.TotalTokens > 0 {
		s.emit("metering", map[string]any{
			"total":            res.Usage.TotalTokens,
			"unit":             "tokens",
			"turn_duration_ms": time.Since(started).Milliseconds(),
			"input_tokens":     res.Usage.InputTokens,
			"output_tokens":    res.Usage.OutputTokens,
			"cached_tokens":    res.Usage.CachedReadTokens,
		})
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
