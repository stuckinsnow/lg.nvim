package hint

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strings"

	"lg-hint-mcp/internal/protocol"
	"lg-pkg/linematch"
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

// HintInScope checks if a hint is within painted regions.
// If match is provided and the line doesn't fall in scope, it reads the file
// and finds the nearest line containing match, then checks that instead.
func HintInScope(file string, line int, match string, regions []protocol.PaintedRegion) bool {
	// Direct line check first
	if lineInRegions(file, line, regions) {
		return true
	}
	// If match provided, find actual line and re-check
	if match == "" {
		return false
	}
	data, err := os.ReadFile(file)
	if err != nil {
		return false
	}
	lines := strings.Split(string(data), "\n")
	foundLine, _, _, ok := linematch.FindNearestLine(lines, line-1, match)
	if !ok {
		return false
	}
	return lineInRegions(file, foundLine+1, regions)
}

func lineInRegions(file string, line int, regions []protocol.PaintedRegion) bool {
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
