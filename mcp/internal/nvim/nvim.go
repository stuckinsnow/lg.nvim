package nvim

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"strings"

	"lg-mcp/internal/protocol"
)

var (
	SockPath  string
	SessionID string
)

func SendToNeovim(req any) ([]byte, error) {
	conn, err := net.Dial("unix", SockPath)
	if err != nil {
		return nil, fmt.Errorf("connect to neovim socket: %w", err)
	}
	defer func() { _ = conn.Close() }()

	data, _ := json.Marshal(req)
	data = append(data, '\n')
	if _, err := conn.Write(data); err != nil {
		return nil, err
	}

	reader := bufio.NewReader(conn)
	return reader.ReadBytes('\n')
}

func GetRegions(editToken string) ([]protocol.NvimRegion, error) {
	req := map[string]string{"method": "get_regions"}
	if SessionID != "" {
		req["session"] = SessionID
	}
	if editToken != "" {
		req["edit_token"] = editToken
	}
	resp, err := SendToNeovim(req)
	if err != nil {
		return nil, err
	}
	var regions []protocol.NvimRegion
	if err := json.Unmarshal(resp, &regions); err != nil {
		return nil, err
	}
	return regions, nil
}

func ApplyEdits(edits []protocol.NvimEdit, editToken string) error {
	req := map[string]any{"method": "apply_edits", "edits": edits}
	if SessionID != "" {
		req["session"] = SessionID
	}
	if editToken != "" {
		req["edit_token"] = editToken
	}
	resp, err := SendToNeovim(req)
	if err != nil {
		return err
	}
	var result struct {
		OK    bool   `json:"ok"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal(resp, &result); err != nil {
		return err
	}
	if result.Error != "" {
		return fmt.Errorf("%s", result.Error)
	}
	return nil
}

func GetDiagnostics(severity int) ([]protocol.Diagnostic, error) {
	resp, err := SendToNeovim(map[string]any{"method": "get_diagnostics", "severity": severity})
	if err != nil {
		return nil, err
	}
	var diags []protocol.Diagnostic
	if err := json.Unmarshal(resp, &diags); err != nil {
		return nil, err
	}
	return diags, nil
}

func FormatDiagnostics(diags []protocol.Diagnostic) string {
	if len(diags) == 0 {
		return "No diagnostics found."
	}
	grouped := map[string][]protocol.Diagnostic{}
	var order []string
	for _, d := range diags {
		if _, ok := grouped[d.File]; !ok {
			order = append(order, d.File)
		}
		grouped[d.File] = append(grouped[d.File], d)
	}
	var sb strings.Builder
	for _, file := range order {
		fmt.Fprintf(&sb, "### %s\n", file)
		for _, d := range grouped[file] {
			src := ""
			if d.Source != "" {
				src = " [" + d.Source + "]"
			}
			fmt.Fprintf(&sb, "- L%d:%d %s: %s%s\n", d.Line, d.Col, d.Severity, d.Message, src)
		}
		sb.WriteString("\n")
	}
	return sb.String()
}
