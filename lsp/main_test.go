package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strings"
	"testing"
	"time"
)

func TestHintSocket(t *testing.T) {
	// Use a temp socket path
	sockPath = "/tmp/lg-hint-test.sock"
	os.Remove(sockPath)

	// Capture LSP output
	origStdout := os.Stdout
	r, w, _ := os.Pipe()
	os.Stdout = w
	stdout = bufio.NewWriter(w)

	startHintSocket()
	time.Sleep(50 * time.Millisecond)

	// Send hints via socket
	conn, err := net.Dial("unix", sockPath)
	if err != nil {
		t.Fatal("dial:", err)
	}

	req := `{"method":"set_hints","hints":[{"file":"/tmp/test.go","line":10,"end_line":10,"column":5,"end_column":15,"message":"possible nil deref","severity":"warning"}]}`
	fmt.Fprintln(conn, req)

	// Read socket response
	scanner := bufio.NewScanner(conn)
	if !scanner.Scan() {
		t.Fatal("no socket response")
	}
	var sockResp struct{ OK bool `json:"ok"` }
	json.Unmarshal(scanner.Bytes(), &sockResp)
	if !sockResp.OK {
		t.Fatal("socket response not ok:", scanner.Text())
	}
	conn.Close()

	// Read LSP output
	stdout.Flush()
	w.Close()
	var lspOut strings.Builder
	buf := make([]byte, 4096)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			lspOut.Write(buf[:n])
		}
		if err != nil {
			break
		}
	}
	r.Close()
	os.Stdout = origStdout

	output := lspOut.String()
	if !strings.Contains(output, "publishDiagnostics") {
		t.Fatal("expected publishDiagnostics in LSP output, got:", output)
	}
	if !strings.Contains(output, "possible nil deref") {
		t.Fatal("expected hint message in output, got:", output)
	}
	if !strings.Contains(output, "file:///tmp/test.go") {
		t.Fatal("expected file URI in output, got:", output)
	}

	// Verify severity (2 = warning)
	// Extract the JSON body after Content-Length header
	idx := strings.Index(output, "{")
	if idx < 0 {
		t.Fatal("no JSON in output")
	}
	var msg lspMessage
	json.Unmarshal([]byte(output[idx:]), &msg)

	var params publishDiagnosticsParams
	json.Unmarshal(msg.Params, &params)

	if len(params.Diagnostics) != 1 {
		t.Fatalf("expected 1 diagnostic, got %d", len(params.Diagnostics))
	}
	d := params.Diagnostics[0]
	if d.Severity != 3 {
		t.Errorf("expected severity 3 (info), got %d", d.Severity)
	}
	if d.Range.Start.Line != 9 { // 0-indexed
		t.Errorf("expected start line 9, got %d", d.Range.Start.Line)
	}
	if d.Range.Start.Character != 4 { // 0-indexed
		t.Errorf("expected start col 4, got %d", d.Range.Start.Character)
	}
	if d.Range.End.Character != 14 { // 0-indexed
		t.Errorf("expected end col 14, got %d", d.Range.End.Character)
	}
	if d.Source != "ai" {
		t.Errorf("expected source 'ai', got %q", d.Source)
	}

	os.Remove(sockPath)
}

func TestHintSocketMatch(t *testing.T) {
	sockPath = "/tmp/lg-hint-match-test.sock"
	os.Remove(sockPath)

	// Create a test file
	os.WriteFile("/tmp/lg-hint-match.go", []byte("package main\n\nfunc foo() {\n\tresult := doSomething(nil)\n}\n"), 0644)

	origStdout := os.Stdout
	r, w, _ := os.Pipe()
	os.Stdout = w
	stdout = bufio.NewWriter(w)

	startHintSocket()
	time.Sleep(50 * time.Millisecond)

	conn, err := net.Dial("unix", sockPath)
	if err != nil {
		t.Fatal("dial:", err)
	}

	req := `{"method":"set_hints","hints":[{"file":"/tmp/lg-hint-match.go","line":4,"end_line":4,"match":"doSomething(nil)","message":"passing nil","severity":"warning"}]}`
	fmt.Fprintln(conn, req)

	scanner := bufio.NewScanner(conn)
	scanner.Scan()
	conn.Close()

	stdout.Flush()
	w.Close()
	var lspOut strings.Builder
	buf := make([]byte, 4096)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			lspOut.Write(buf[:n])
		}
		if err != nil {
			break
		}
	}
	r.Close()
	os.Stdout = origStdout

	output := lspOut.String()
	idx := strings.Index(output, "{")
	var msg lspMessage
	json.Unmarshal([]byte(output[idx:]), &msg)

	var params publishDiagnosticsParams
	json.Unmarshal(msg.Params, &params)

	if len(params.Diagnostics) != 1 {
		t.Fatalf("expected 1 diagnostic, got %d", len(params.Diagnostics))
	}
	d := params.Diagnostics[0]
	// "\tresult := doSomething(nil)" — tab(1) + "result := "(10) = col 11, match is 16 chars
	if d.Range.Start.Character != 11 {
		t.Errorf("expected start col 11, got %d", d.Range.Start.Character)
	}
	if d.Range.End.Character != 27 {
		t.Errorf("expected end col 27, got %d", d.Range.End.Character)
	}

	os.Remove(sockPath)
	os.Remove("/tmp/lg-hint-match.go")
}

func TestHintSocketClear(t *testing.T) {
	sockPath = "/tmp/lg-hint-clear-test.sock"
	os.Remove(sockPath)

	origStdout := os.Stdout
	r, w, _ := os.Pipe()
	os.Stdout = w
	stdout = bufio.NewWriter(w)

	startHintSocket()
	time.Sleep(50 * time.Millisecond)

	conn, err := net.Dial("unix", sockPath)
	if err != nil {
		t.Fatal("dial:", err)
	}

	// Clear with file list
	req := `{"method":"clear","hints":[{"file":"/tmp/test.go","line":1,"message":"","severity":""}]}`
	fmt.Fprintln(conn, req)

	scanner := bufio.NewScanner(conn)
	if !scanner.Scan() {
		t.Fatal("no response")
	}
	conn.Close()

	stdout.Flush()
	w.Close()
	var lspOut strings.Builder
	buf := make([]byte, 4096)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			lspOut.Write(buf[:n])
		}
		if err != nil {
			break
		}
	}
	r.Close()
	os.Stdout = origStdout

	output := lspOut.String()
	if !strings.Contains(output, "publishDiagnostics") {
		t.Fatal("expected publishDiagnostics for clear")
	}
	// Should have empty diagnostics array
	if !strings.Contains(output, `"diagnostics":[]`) {
		t.Fatal("expected empty diagnostics array, got:", output)
	}

	os.Remove(sockPath)
}
