package main

import (
	"bufio"

	"lg-lsp/internal/hints"
	"lg-lsp/internal/lsptype"
	"lg-lsp/internal/socket"
	"lg-lsp/internal/transport"
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
	transport.Writer = bufio.NewWriter(w)

	socket.Start(sockPath)
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
	transport.Writer.Flush()
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
	var msg lsptype.Message
	json.Unmarshal([]byte(output[idx:]), &msg)

	var params lsptype.PublishDiagnosticsParams
	json.Unmarshal(msg.Params, &params)

	if len(params.Diagnostics) != 1 {
		t.Fatalf("expected 1 diagnostic, got %d", len(params.Diagnostics))
	}
	d := params.Diagnostics[0]
	if d.Severity != 4 {
		t.Errorf("expected severity 4 (hint), got %d", d.Severity)
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
	transport.Writer = bufio.NewWriter(w)

	socket.Start(sockPath)
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

	transport.Writer.Flush()
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
	var msg lsptype.Message
	json.Unmarshal([]byte(output[idx:]), &msg)

	var params lsptype.PublishDiagnosticsParams
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

func TestHover(t *testing.T) {
	sockPath = "/tmp/lg-hint-hover-test.sock"
	os.Remove(sockPath)

	// Reset stored diags
	hints.Mu.Lock()
	hints.Diags = map[string][]lsptype.Diagnostic{}
	hints.Mu.Unlock()

	origStdout := os.Stdout
	r, w, _ := os.Pipe()
	os.Stdout = w
	transport.Writer = bufio.NewWriter(w)

	socket.Start(sockPath)
	time.Sleep(50 * time.Millisecond)

	// Publish a hint at line 10, cols 4-14
	conn, err := net.Dial("unix", sockPath)
	if err != nil {
		t.Fatal("dial:", err)
	}
	req := `{"method":"set_hints","hints":[{"file":"/tmp/hover-test.go","line":10,"end_line":10,"column":5,"end_column":15,"message":"suggestion:\n` + "```go\\nfixed code\\n```" + `","severity":"hint"}]}`
	fmt.Fprintln(conn, req)
	scanner := bufio.NewScanner(conn)
	scanner.Scan()
	conn.Close()

	// Drain the publishDiagnostics output
	transport.Writer.Flush()

	// Now simulate a textDocument/hover LSP request by calling the handler directly
	// We check storedDiags to verify hover would work
	hints.Mu.Lock()
	uri := "file:///tmp/hover-test.go"
	diags := hints.Diags[uri]
	hints.Mu.Unlock()

	if len(diags) != 1 {
		// drain pipe before fatal
		w.Close()
		buf := make([]byte, 4096)
		for { n, err := r.Read(buf); if n == 0 || err != nil { break } }
		r.Close()
		os.Stdout = origStdout
		t.Fatalf("expected 1 diagnostic, got %d", len(diags))
	}

	// Verify the diagnostic is at the right position for hover hit-testing
	d := diags[0]
	// Hover at line 9 (0-based), col 5 — should be inside range [4,14)
	pos := lsptype.Position{Line: 9, Character: 5}
	hit := d.Range.Start.Line <= pos.Line && d.Range.End.Line >= pos.Line &&
		(d.Range.Start.Line < pos.Line || d.Range.Start.Character <= pos.Character) &&
		(d.Range.End.Line > pos.Line || d.Range.End.Character >= pos.Character)
	if !hit {
		w.Close()
		buf := make([]byte, 4096)
		for { n, err := r.Read(buf); if n == 0 || err != nil { break } }
		r.Close()
		os.Stdout = origStdout
		t.Fatalf("hover at (9,5) should hit diagnostic at range (%d,%d)-(%d,%d)",
			d.Range.Start.Line, d.Range.Start.Character, d.Range.End.Line, d.Range.End.Character)
	}

	// Diagnostic should have the message
	if !strings.Contains(d.Message, "suggestion") {
		w.Close()
		buf := make([]byte, 4096)
		for { n, err := r.Read(buf); if n == 0 || err != nil { break } }
		r.Close()
		os.Stdout = origStdout
		t.Fatalf("expected 'suggestion' in diagnostic message, got: %s", d.Message)
	}

	// Hover at line 0, col 0 — should miss
	pos2 := lsptype.Position{Line: 0, Character: 0}
	hit2 := d.Range.Start.Line <= pos2.Line && d.Range.End.Line >= pos2.Line
	if hit2 {
		w.Close()
		buf := make([]byte, 4096)
		for { n, err := r.Read(buf); if n == 0 || err != nil { break } }
		r.Close()
		os.Stdout = origStdout
		t.Fatal("hover at (0,0) should NOT hit diagnostic")
	}

	w.Close()
	buf := make([]byte, 4096)
	for { n, err := r.Read(buf); if n == 0 || err != nil { break } }
	r.Close()
	os.Stdout = origStdout
	os.Remove(sockPath)
}

func TestGetHints(t *testing.T) {
	sockPath = "/tmp/lg-hint-get-test.sock"
	os.Remove(sockPath)

	hints.Mu.Lock()
	hints.Diags = map[string][]lsptype.Diagnostic{}
	hints.Details = map[string][]string{}
	hints.Mu.Unlock()

	origStdout := os.Stdout
	r, w, _ := os.Pipe()
	os.Stdout = w
	transport.Writer = bufio.NewWriter(w)

	socket.Start(sockPath)
	time.Sleep(50 * time.Millisecond)

	conn, err := net.Dial("unix", sockPath)
	if err != nil {
		t.Fatal("dial:", err)
	}
	setReq := `{"method":"set_hints","hints":[{"file":"/tmp/get-test.go","line":10,"end_line":10,"column":5,"end_column":15,"message":"possible nil deref","detail":"### fix\n` + "```go\\ncheck != nil\\n```" + `","severity":"hint"}]}`
	fmt.Fprintln(conn, setReq)
	sc := bufio.NewScanner(conn)
	sc.Scan()

	fmt.Fprintln(conn, `{"method":"get_hints"}`)
	if !sc.Scan() {
		t.Fatal("no get_hints response")
	}
	getLine := sc.Text()
	conn.Close()

	transport.Writer.Flush()
	w.Close()
	buf := make([]byte, 4096)
	for {
		n, err := r.Read(buf)
		if n == 0 || err != nil {
			break
		}
	}
	r.Close()
	os.Stdout = origStdout

	var got struct {
		OK    bool               `json:"ok"`
		Hints []hints.StoredHint `json:"hints"`
	}
	if err := json.Unmarshal([]byte(getLine), &got); err != nil {
		t.Fatal("unmarshal get_hints response:", err, getLine)
	}
	if !got.OK {
		t.Fatal("get_hints not ok:", getLine)
	}
	if len(got.Hints) != 1 {
		t.Fatalf("expected 1 hint, got %d: %s", len(got.Hints), getLine)
	}
	h := got.Hints[0]
	if h.File != "/tmp/get-test.go" {
		t.Errorf("expected file /tmp/get-test.go, got %q", h.File)
	}
	if h.Line != 10 {
		t.Errorf("expected 1-based line 10, got %d", h.Line)
	}
	if h.Column != 5 {
		t.Errorf("expected 1-based column 5, got %d", h.Column)
	}
	if h.EndColumn != 15 {
		t.Errorf("expected 1-based end column 15, got %d", h.EndColumn)
	}
	if h.Message != "possible nil deref" {
		t.Errorf("expected message, got %q", h.Message)
	}
	if !strings.Contains(h.Detail, "check != nil") {
		t.Errorf("expected detail to contain suggestion code, got %q", h.Detail)
	}

	os.Remove(sockPath)
}

func TestGetHintsFilter(t *testing.T) {
	sockPath = "/tmp/lg-hint-getfilter-test.sock"
	os.Remove(sockPath)

	hints.Mu.Lock()
	hints.Diags = map[string][]lsptype.Diagnostic{}
	hints.Details = map[string][]string{}
	hints.Mu.Unlock()

	origStdout := os.Stdout
	r, w, _ := os.Pipe()
	os.Stdout = w
	transport.Writer = bufio.NewWriter(w)

	socket.Start(sockPath)
	time.Sleep(50 * time.Millisecond)

	conn, err := net.Dial("unix", sockPath)
	if err != nil {
		t.Fatal("dial:", err)
	}
	fmt.Fprintln(conn, `{"method":"set_hints","hints":[{"file":"/tmp/a.go","line":1,"message":"a","severity":"hint"}]}`)
	sc := bufio.NewScanner(conn)
	sc.Scan()
	fmt.Fprintln(conn, `{"method":"set_hints","hints":[{"file":"/tmp/b.go","line":1,"message":"b","severity":"hint"}]}`)
	sc.Scan()

	fmt.Fprintln(conn, `{"method":"get_hints","file":"/tmp/b.go"}`)
	if !sc.Scan() {
		t.Fatal("no get_hints response")
	}
	getLine := sc.Text()
	conn.Close()

	transport.Writer.Flush()
	w.Close()
	buf := make([]byte, 4096)
	for {
		n, err := r.Read(buf)
		if n == 0 || err != nil {
			break
		}
	}
	r.Close()
	os.Stdout = origStdout

	var got struct {
		Hints []hints.StoredHint `json:"hints"`
	}
	json.Unmarshal([]byte(getLine), &got)
	if len(got.Hints) != 1 {
		t.Fatalf("expected 1 filtered hint, got %d: %s", len(got.Hints), getLine)
	}
	if got.Hints[0].File != "/tmp/b.go" {
		t.Errorf("expected only /tmp/b.go, got %q", got.Hints[0].File)
	}

	os.Remove(sockPath)
}

func TestHintSocketClear(t *testing.T) {
	sockPath = "/tmp/lg-hint-clear-test.sock"
	os.Remove(sockPath)

	origStdout := os.Stdout
	r, w, _ := os.Pipe()
	os.Stdout = w
	transport.Writer = bufio.NewWriter(w)

	socket.Start(sockPath)
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

	transport.Writer.Flush()
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
