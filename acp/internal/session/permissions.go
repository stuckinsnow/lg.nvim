package session

import (
	"encoding/json"
	"lg-acp/internal/protocol"
	"log"
	"path/filepath"
	"strings"
)

// Permission policy for session/request_permission. Kiro v3 requests carry
// _meta.kiro.consent and are decided by capability; requests without it
// (opencode) fall back to matching the tool title.

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
	title, kind := "", ""
	if params.ToolCall != nil {
		title = params.ToolCall.Title
		kind = params.ToolCall.Kind
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
	needsApproval := kind == "execute" || kind == "edit" || kind == "delete" || kind == "move" ||
		strings.HasPrefix(title, "Creating ") ||
		strings.HasPrefix(title, "Deleting ") ||
		(strings.HasPrefix(title, "Running") && !strings.Contains(title, "@lg/") && !strings.Contains(title, "@lg-hint/")) ||
		strings.Contains(strings.ToLower(title), "devlens")
	if needsApproval {
		s.ask(id, opts, title, "")
		return
	}
	s.allow(id, opts, title)
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
