package protocol

import (
	"regexp"
	"strconv"
	"strings"
)

// Agents like opencode log a failed model call to stderr and never answer the
// pending session/prompt, so the turn would hang. These lines are logfmt:
//
//	timestamp=… level=ERROR message="stream error" session.id=ses_… small=false error.error="AI_APICallError: …"
var (
	logSessionRe = regexp.MustCompile(`\bsession\.id=(\S+)`)
	logErrorRe   = regexp.MustCompile(`\berror\.error=("(?:[^"\\]|\\.)*"|\S+)`)
)

// ParseAgentError extracts the session id and error text from an agent's
// stderr log line. ok is false unless the line is an ERROR for a session's
// main turn; background calls (small=true, e.g. title generation) are skipped
// because their failure doesn't stall the turn.
func ParseAgentError(line string) (sessionID, msg string, ok bool) {
	if !strings.Contains(line, "level=ERROR") || strings.Contains(line, "small=true") {
		return "", "", false
	}
	sm := logSessionRe.FindStringSubmatch(line)
	em := logErrorRe.FindStringSubmatch(line)
	if sm == nil || em == nil {
		return "", "", false
	}
	msg = em[1]
	if unq, err := strconv.Unquote(msg); err == nil {
		msg = unq
	}
	return sm[1], msg, true
}
