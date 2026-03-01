package hint

import (
	"bufio"
	"encoding/json"
	"fmt"
	"lg-hint-mcp/internal/protocol"
	"net"
	"os"
)

var (
	HintSockPath string
	LgSockPath   string
)

func init() {
	HintSockPath = os.Getenv("LG_HINT_SOCK")
	if HintSockPath == "" {
		HintSockPath = "/dev/shm/lg-hint.sock"
	}
	LgSockPath = os.Getenv("LG_SOCK")
	if LgSockPath == "" {
		LgSockPath = "/dev/shm/lg.sock"
	}
}

func GetPaintedRegions() []protocol.PaintedRegion {
	conn, err := net.Dial("unix", LgSockPath)
	if err != nil {
		return nil
	}
	defer func() { _ = conn.Close() }()
	data, _ := json.Marshal(map[string]string{"method": "get_regions"})
	if _, err := conn.Write(append(data, '\n')); err != nil {
		return nil
	}
	resp, err := bufio.NewReader(conn).ReadBytes('\n')
	if err != nil {
		return nil
	}
	var regions []protocol.PaintedRegion
	if err := json.Unmarshal(resp, &regions); err != nil {
		return nil
	}
	return regions
}

func HintInScope(file string, line int, regions []protocol.PaintedRegion) bool {
	for _, r := range regions {
		if r.File == file && line >= r.StartLine && line <= r.EndLine {
			return true
		}
	}
	return false
}

func SendToLSP(req any) ([]byte, error) {
	conn, err := net.Dial("unix", HintSockPath)
	if err != nil {
		return nil, fmt.Errorf("connect to hint LSP: %w", err)
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
