package server

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

type sessionEntry struct {
	ID      string `json:"id"`
	Title   string `json:"title"`
	Date    string `json:"date"`
	Preview string `json:"preview"`
}

// listSessions returns session history for the given provider and cwd.
func listSessions(provider, cwd string) (json.RawMessage, error) {
	if provider == "opencode" {
		return listOpencodeSessions(cwd)
	}
	return listKiroSessions(cwd)
}

// deleteSession removes a session for the given provider.
func deleteSession(provider, sessionID string) error {
	if provider == "opencode" {
		return deleteOpencodeSession(sessionID)
	}
	home, _ := os.UserHomeDir()
	return os.Remove(filepath.Join(home, ".kiro", "sessions", "cli", sessionID+".json"))
}

func listOpencodeSessions(cwd string) (json.RawMessage, error) {
	home, _ := os.UserHomeDir()
	dbPath := filepath.Join(home, ".local", "share", "opencode", "opencode.db")
	if _, err := os.Stat(dbPath); err != nil {
		return json.Marshal([]sessionEntry{})
	}

	query := fmt.Sprintf(`SELECT json_group_array(json_object(
		'id', s.id, 'title', s.title,
		'date', datetime(s.time_updated / 1000, 'unixepoch', 'localtime'),
		'preview', (SELECT group_concat(json_extract(p.data, '$.text'), char(10)||'---'||char(10))
		            FROM (SELECT p2.data FROM part p2
		                  WHERE p2.session_id = s.id
		                  AND json_extract(p2.data, '$.type') = 'text'
		                  ORDER BY p2.time_created LIMIT 2) p)
	)) FROM (
		SELECT * FROM session s WHERE s.directory = '%s'
		AND s.title NOT LIKE 'ACP Session %%'
		AND s.title NOT LIKE 'New session - %%'
		ORDER BY s.time_updated DESC LIMIT 50
	) s`, cwd)

	out, err := exec.Command("sqlite3", dbPath, query).Output()
	if err != nil {
		return nil, fmt.Errorf("sqlite3: %w", err)
	}
	return json.RawMessage(out), nil
}

type kiroFile struct {
	SessionID string `json:"session_id"`
	CWD       string `json:"cwd"`
	UpdatedAt string `json:"updated_at"`
	State     struct {
		Conv struct {
			Turns []struct {
				Result struct {
					Ok struct {
						Content []struct {
							Kind string `json:"kind"`
							Data string `json:"data"`
						} `json:"content"`
					} `json:"Ok"`
				} `json:"result"`
			} `json:"user_turn_metadatas"`
		} `json:"conversation_metadata"`
	} `json:"session_state"`
}

func listKiroSessions(cwd string) (json.RawMessage, error) {
	home, _ := os.UserHomeDir()
	dir := filepath.Join(home, ".kiro", "sessions", "cli")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return json.Marshal([]sessionEntry{})
	}

	var sessions []sessionEntry
	for _, e := range entries {
		if filepath.Ext(e.Name()) != ".json" {
			continue
		}
		data, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			continue
		}
		var f kiroFile
		if json.Unmarshal(data, &f) != nil || f.CWD != cwd {
			continue
		}

		var title string
		var previewLines int
		var preview strings.Builder
		for _, turn := range f.State.Conv.Turns {
			for _, c := range turn.Result.Ok.Content {
				if c.Kind == "text" && c.Data != "" {
					text := strings.TrimLeft(c.Data, " \t\n")
					if title == "" {
						first, _, _ := strings.Cut(text, "\n")
						if len(first) > 80 {
							first = first[:80]
						}
						title = first
					}
					for _, line := range strings.Split(text, "\n") {
						if previewLines > 0 {
							preview.WriteByte('\n')
						}
						preview.WriteString(line)
						previewLines++
						if previewLines >= 40 {
							break
						}
					}
				}
			}
			if previewLines >= 40 {
				break
			}
		}
		if title == "" {
			title = "(untitled)"
		}

		date := f.UpdatedAt
		if len(date) > 16 {
			date = date[:16]
		}
		date = strings.ReplaceAll(date, "T", " ")

		p := preview.String()
		if strings.TrimSpace(p) == "" {
			continue
		}
		sessions = append(sessions, sessionEntry{
			ID:      f.SessionID,
			Title:   title,
			Date:    date,
			Preview: p,
		})
	}

	sort.Slice(sessions, func(i, j int) bool {
		return sessions[i].Date > sessions[j].Date
	})
	if len(sessions) > 50 {
		sessions = sessions[:50]
	}
	return json.Marshal(sessions)
}

func deleteOpencodeSession(sessionID string) error {
	home, _ := os.UserHomeDir()
	dbPath := filepath.Join(home, ".local", "share", "opencode", "opencode.db")
	return exec.Command("sqlite3", dbPath, fmt.Sprintf("DELETE FROM session WHERE id = '%s'", sessionID)).Run()
}
