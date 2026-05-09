// Package bridge connects lg-acp to the lg neovim socket (same one the MCP
// binaries use) so we can read buffer content instead of disk content when
// the file is open in nvim with unsaved changes.
package bridge

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"time"
)

// socketPath returns the lg neovim socket path, honoring LG_SOCK env.
func socketPath() string {
	if p := os.Getenv("LG_SOCK"); p != "" {
		return p
	}
	return "/dev/shm/lg.sock"
}

// ReadBuffer asks lg.nvim for the buffer content of the given file.
// Returns (content, true, nil) if the file is open in a buffer,
// ("", false, nil) if the buffer isn't loaded (fall back to disk),
// or ("", false, err) on connection/protocol failure.
func ReadBuffer(path string) (string, bool, error) {
	sock := socketPath()
	conn, err := net.DialTimeout("unix", sock, 500*time.Millisecond)
	if err != nil {
		return "", false, fmt.Errorf("lg socket: %w", err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(1500 * time.Millisecond))

	req := map[string]any{"method": "read_buffer", "path": path}
	data, _ := json.Marshal(req)
	data = append(data, '\n')
	if _, err := conn.Write(data); err != nil {
		return "", false, err
	}

	reader := bufio.NewReader(conn)
	line, err := reader.ReadBytes('\n')
	if err != nil {
		return "", false, err
	}

	var resp struct {
		Content   string `json:"content"`
		Error     string `json:"error"`
		StartLine int    `json:"start_line"`
		EndLine   int    `json:"end_line"`
		Total     int    `json:"total_lines"`
		// When file is not in any buffer, lg server returns a result
		// that reads from disk. We want to distinguish buffer vs disk,
		// but the response shape is the same — so we treat any success
		// as "use this content" (lg's read_buffer does buffer-first fallback
		// to disk internally, which is exactly what we want).
	}
	if err := json.Unmarshal(line, &resp); err != nil {
		return "", false, err
	}
	if resp.Error != "" {
		return "", false, fmt.Errorf("%s", resp.Error)
	}
	return resp.Content, true, nil
}
