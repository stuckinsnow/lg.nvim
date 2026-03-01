package socket

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"

	"lg-lsp/internal/hints"
	"lg-lsp/internal/lsptype"
	"lg-lsp/internal/transport"
)

func Start(sockPath string) {
	os.Remove(sockPath)
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "hint socket: %v\n", err)
		return
	}
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				scanner := bufio.NewScanner(c)
				scanner.Buffer(make([]byte, 1024*1024), 1024*1024)
				for scanner.Scan() {
					var req lsptype.HintRequest
					if err := json.Unmarshal(scanner.Bytes(), &req); err != nil {
						c.Write([]byte(`{"error":"invalid json"}` + "\n"))
						continue
					}
					switch req.Method {
					case "set_hints":
						total, matched, failures := hints.Publish(req.Hints)
						resp := map[string]any{"ok": true, "total": total, "matched": matched}
						if len(failures) > 0 {
							resp["failures"] = failures
						}
						out, _ := json.Marshal(resp)
						c.Write(append(out, '\n'))
					case "clear":
						hints.Mu.Lock()
						if len(req.Hints) > 0 {
							seen := map[string]bool{}
							for _, h := range req.Hints {
								uri := hints.FileToURI(h.File)
								if !seen[uri] {
									seen[uri] = true
									delete(hints.Diags, uri)
								delete(hints.Details, uri)
									params, _ := json.Marshal(lsptype.PublishDiagnosticsParams{URI: uri, Diagnostics: []lsptype.Diagnostic{}})
									transport.Send(lsptype.Message{JSONRPC: "2.0", Method: "textDocument/publishDiagnostics", Params: params})
								}
							}
						} else {
							for uri := range hints.Diags {
								params, _ := json.Marshal(lsptype.PublishDiagnosticsParams{URI: uri, Diagnostics: []lsptype.Diagnostic{}})
								transport.Send(lsptype.Message{JSONRPC: "2.0", Method: "textDocument/publishDiagnostics", Params: params})
							}
							hints.Diags = map[string][]lsptype.Diagnostic{}
							hints.Details = map[string][]string{}
						}
						hints.Mu.Unlock()
						c.Write([]byte(`{"ok":true}` + "\n"))
					default:
						c.Write([]byte(`{"error":"unknown method"}` + "\n"))
					}
				}
			}(conn)
		}
	}()
}

