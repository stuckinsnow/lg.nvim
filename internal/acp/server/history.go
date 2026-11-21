// Session history for opencode, read from its sqlite database. Kiro sessions
// go through ACP (session/list, _kiro/session/delete) instead.

package server

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

func listOpencodeSessions(cwd string) (json.RawMessage, error) {
	home, _ := os.UserHomeDir()
	dbPath := filepath.Join(home, ".local", "share", "opencode", "opencode.db")
	if _, err := os.Stat(dbPath); err != nil {
		return json.Marshal([]sessionEntry{})
	}

	query := fmt.Sprintf(`SELECT json_group_array(json_object(
		'id', s.id, 'title', s.title,
		'date', datetime(s.time_updated / 1000, 'unixepoch', 'localtime')
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

func deleteOpencodeSession(sessionID string) error {
	home, _ := os.UserHomeDir()
	dbPath := filepath.Join(home, ".local", "share", "opencode", "opencode.db")
	return exec.Command("sqlite3", dbPath, fmt.Sprintf("DELETE FROM session WHERE id = '%s'", sessionID)).Run()
}
