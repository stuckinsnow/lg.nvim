package server

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

const (
	maxPreviewTurns = 6
	maxPreviewLines = 100
	maxTurnChars    = 800
	scannerBufMax   = 4 * 1024 * 1024
)

type previewTurn struct {
	Role string
	Text string
}

var previewers = map[string]func(sessionID string) string{
	"opencode":    previewOpencodeSession,
	"antigravity": previewAntigravitySession,
	"kiro":        previewKiroSession,
}

// PreviewSession returns a Markdown preview for a single session, or "" if unavailable.
func PreviewSession(provider, sessionID string) string {
	if sessionID == "" || strings.ContainsAny(sessionID, "/\\") || strings.Contains(sessionID, "..") {
		return ""
	}
	fn, ok := previewers[provider]
	if !ok {
		return ""
	}
	return fn(sessionID)
}

func appendTurn(turns []previewTurn, t previewTurn) []previewTurn {
	turns = append(turns, t)
	if len(turns) > maxPreviewTurns {
		turns = turns[len(turns)-maxPreviewTurns:]
	}
	return turns
}

func formatPreview(turns []previewTurn) string {
	if len(turns) == 0 {
		return ""
	}
	var b strings.Builder
	for i, t := range turns {
		if i > 0 {
			b.WriteString("\n\n---\n\n")
		}
		if t.Role != "" {
			fmt.Fprintf(&b, "**%s:**\n", t.Role)
		}
		text := strings.TrimSpace(t.Text)
		if runes := []rune(text); len(runes) > maxTurnChars {
			text = string(runes[:maxTurnChars]) + "..."
		}
		b.WriteString(text)
	}
	lines := strings.Split(b.String(), "\n")
	if len(lines) > maxPreviewLines {
		lines = lines[len(lines)-maxPreviewLines:]
	}
	return strings.Join(lines, "\n")
}

func previewOpencodeSession(sessionID string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	dbPath := filepath.Join(home, ".local", "share", "opencode", "opencode.db")
	if _, err := os.Stat(dbPath); err != nil {
		return ""
	}

	safeID := strings.ReplaceAll(sessionID, "'", "''")
	query := fmt.Sprintf(`SELECT COALESCE(json_group_array(text), '[]') FROM (
		SELECT text FROM (
			SELECT json_extract(p.data, '$.text') AS text, p.time_created
			FROM part p
			WHERE p.session_id = '%s'
			AND json_extract(p.data, '$.type') = 'text'
			ORDER BY p.time_created DESC
			LIMIT %d
		) ORDER BY time_created ASC
	)`, safeID, maxPreviewTurns)

	out, err := exec.Command("sqlite3", dbPath, query).Output()
	if err != nil {
		return ""
	}
	var texts []string
	if err := json.Unmarshal(out, &texts); err != nil {
		return ""
	}
	var turns []previewTurn
	for _, t := range texts {
		if strings.TrimSpace(t) != "" {
			turns = append(turns, previewTurn{Text: t})
		}
	}
	return formatPreview(turns)
}

func previewAntigravitySession(sessionID string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	path := filepath.Join(home, ".gemini", "antigravity-cli", "brain", sessionID, ".system_generated", "logs", "transcript.jsonl")
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()

	var turns []previewTurn
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), scannerBufMax)
	for scanner.Scan() {
		var entry struct {
			Type    string `json:"type"`
			Content string `json:"content"`
		}
		if json.Unmarshal(scanner.Bytes(), &entry) != nil {
			continue
		}
		switch entry.Type {
		case "USER_INPUT":
			text := cleanUserRequest(entry.Content)
			if text != "" {
				turns = appendTurn(turns, previewTurn{Role: "User", Text: text})
			}
		case "PLANNER_RESPONSE":
			if strings.TrimSpace(entry.Content) != "" {
				turns = appendTurn(turns, previewTurn{Role: "Assistant", Text: entry.Content})
			}
		}
	}
	return formatPreview(turns)
}

func cleanUserRequest(s string) string {
	if start := strings.Index(s, "<USER_REQUEST>"); start >= 0 {
		s = s[start+len("<USER_REQUEST>"):]
		if end := strings.Index(s, "</USER_REQUEST>"); end >= 0 {
			s = s[:end]
		}
	}
	return strings.TrimSpace(s)
}

func previewKiroSession(sessionID string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	pattern := filepath.Join(home, ".kiro", "sessions", "*", sessionID, "messages.jsonl")
	matches, err := filepath.Glob(pattern)
	if err != nil || len(matches) == 0 {
		return ""
	}
	f, err := os.Open(matches[0])
	if err != nil {
		return ""
	}
	defer f.Close()

	var turns []previewTurn
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), scannerBufMax)
	for scanner.Scan() {
		var entry struct {
			Payload struct {
				Type          string `json:"type"`
				Content       string `json:"content"`
				OperationType string `json:"operationType"`
			} `json:"payload"`
		}
		if json.Unmarshal(scanner.Bytes(), &entry) != nil {
			continue
		}
		if strings.TrimSpace(entry.Payload.Content) == "" {
			continue
		}
		switch entry.Payload.Type {
		case "user":
			turns = appendTurn(turns, previewTurn{Role: "User", Text: entry.Payload.Content})
		case "assistant":
			if entry.Payload.OperationType != "Reasoning" {
				turns = appendTurn(turns, previewTurn{Role: "Assistant", Text: entry.Payload.Content})
			}
		}
	}
	return formatPreview(turns)
}
