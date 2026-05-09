package session

import "strings"

// Decision from the per-mode permission filter.
type ModeDecision int

const (
	DecisionUnknown ModeDecision = iota // Fall through to existing logic
	DecisionAllow                       // Auto-approve
	DecisionDeny                        // Auto-reject
)

// isReadOnlyToolTitle returns true if the tool call is clearly read-only
// based on kiro/cursor permission titles we've seen in the wild.
func isReadOnlyToolTitle(lowerTitle string) bool {
	// Title patterns: "Reading foo.lua:1", "grep", "glob", "code ...".
	if strings.HasPrefix(lowerTitle, "reading ") {
		return true
	}
	// Built-in read-only tools
	for _, kw := range []string{"grep", "glob", "list_directory", "thinking", "todo_list", "introspect"} {
		if strings.Contains(lowerTitle, kw) {
			return true
		}
	}
	// The `code` tool's non-write operations (all are read-only in practice)
	if strings.HasPrefix(lowerTitle, "code ") || strings.HasPrefix(lowerTitle, "code:") {
		return true
	}
	return false
}

// isWriteToolTitle returns true if the title looks like a direct file write
// (cursor/kiro built-in write, edit, create, delete tools). Used to detect
// and block native file writes in lg mode so edits go through paint_edit.
func isWriteToolTitle(lowerTitle string) bool {
	for _, prefix := range []string{
		"editing ", "writing ", "creating ", "deleting ", "modifying ",
	} {
		if strings.HasPrefix(lowerTitle, prefix) {
			return true
		}
	}
	// Cursor's built-in write tool title: "write ..." or tool names
	for _, kw := range []string{
		// Built-in write/edit tool names (seen in kiro + cursor)
		"write_text_file", "str_replace", "strreplace",
	} {
		if strings.Contains(lowerTitle, kw) {
			return true
		}
	}
	return false
}

// containsMCP returns true if the title references the given MCP server name.
// Cursor formats permission titles as "probe-ping: ping" (serverName + dash + tool).
// Kiro uses "@server/tool" format.
func containsMCP(lowerTitle, server string) bool {
	return strings.Contains(lowerTitle, "@"+server+"/") ||
		strings.Contains(lowerTitle, server+"-") ||
		strings.Contains(lowerTitle, server+":")
}

// ModeFilter decides whether to auto-allow/deny a tool call based on the
// current logical mode. This is the client-side equivalent of kiro's
// per-agent tool allowlist — applied for providers (cursor, opencode) that
// don't have that mechanism natively.
//
// Returns DecisionUnknown to fall through to the existing permission logic.
func ModeFilter(provider, logicalMode, title string) ModeDecision {
	// Kiro already enforces tool allowlists per-agent server-side.
	// Opencode has its own mode system; leave its behavior unchanged.
	if provider != "cursor" || logicalMode == "" {
		return DecisionUnknown
	}

	lt := strings.ToLower(title)

	switch logicalMode {
	// ─── Read-only / review-style modes ────────────────────────────────
	case "asker", "reviewer", "suggester", "helper", "lg-info", "lg-plan", "kiro_planner":
		// Always allow read-only built-ins
		if isReadOnlyToolTitle(lt) {
			return DecisionAllow
		}
		// Reviewer/suggester/helper need lg-hint to publish diagnostics
		if (logicalMode == "reviewer" || logicalMode == "suggester" || logicalMode == "helper") &&
			containsMCP(lt, "lg-hint") {
			return DecisionAllow
		}
		// Anything else (paint_edit, file writes, shell) → deny
		return DecisionDeny

	// ─── Full-edit lg modes ────────────────────────────────────────────
	case "lg", "lg-chat", "lg-oneshot":
		// Allow lg MCP tools (paint_edit, get_painted_regions, etc.)
		if containsMCP(lt, "lg") || containsMCP(lt, "lg-hint") || containsMCP(lt, "lg-git") {
			return DecisionAllow
		}
		// Allow read-only built-ins
		if isReadOnlyToolTitle(lt) {
			return DecisionAllow
		}
		// Force edits through paint_edit — deny direct file writes so the
		// AI can't bypass the painted-region constraint.
		if isWriteToolTitle(lt) {
			return DecisionDeny
		}
		// Shell/other falls through to existing approval flow
		return DecisionUnknown

	case "fullstack", "kiro_default":
		// Fullstack: unconstrained. Allow MCP + read-only; file writes and
		// shell still route to user approval via existing flow.
		if containsMCP(lt, "lg") || containsMCP(lt, "lg-hint") || containsMCP(lt, "lg-git") {
			return DecisionAllow
		}
		if isReadOnlyToolTitle(lt) {
			return DecisionAllow
		}
		return DecisionUnknown

	// ─── DevLens / browser debugging ───────────────────────────────────
	case "devlens":
		if containsMCP(lt, "devlens") {
			return DecisionAllow
		}
		if isReadOnlyToolTitle(lt) {
			return DecisionAllow
		}
		return DecisionDeny
	}

	return DecisionUnknown
}

// ShouldBlockDirectWrite returns true if direct file writes (fs/write_text_file)
// should be rejected for the given provider + logical mode. This gates cursor's
// built-in Edit File / Create File tools, which don't go through
// session/request_permission and therefore bypass ModeFilter.
//
// In strict modes, any write must go through the paint_edit MCP tool instead.
func ShouldBlockDirectWrite(provider, logicalMode string) bool {
	if provider != "cursor" || logicalMode == "" {
		return false
	}
	switch logicalMode {
	// Read-only modes: never allow writes.
	case "asker", "reviewer", "suggester", "helper", "lg-info", "lg-plan", "kiro_planner":
		return true
	// Paint-constrained modes: force edits through paint_edit.
	case "lg", "lg-chat", "lg-oneshot":
		return true
	// DevLens: read-only inspection.
	case "devlens":
		return true
	// fullstack/kiro_default: allow direct writes (the whole point).
	}
	return false
}
