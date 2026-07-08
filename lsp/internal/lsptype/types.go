package lsptype

import "encoding/json"

// NullResult is a sentinel value to emit "result": null in JSON.
var NullResult = json.RawMessage("null")

type Message struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      any             `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
	Result  any             `json:"result,omitempty"`
}

type Position struct {
	Line      int `json:"line"`
	Character int `json:"character"`
}

type Range struct {
	Start Position `json:"start"`
	End   Position `json:"end"`
}

type Diagnostic struct {
	Range    Range `json:"range"`
	Severity int      `json:"severity"`
	Source   string   `json:"source"`
	Message  string   `json:"message"`
}

type PublishDiagnosticsParams struct {
	URI         string       `json:"uri"`
	Diagnostics []Diagnostic `json:"diagnostics"`
}

// ── Hint socket types ──────────────────────────────────────────────

type Hint struct {
	File      string `json:"file"`
	Line      int    `json:"line"`
	EndLine   int    `json:"end_line"`
	Column    int    `json:"column"`
	EndColumn int    `json:"end_column"`
	Match     string `json:"match"`
	Message   string `json:"message"`
	Detail    string `json:"detail"`
	Severity  string `json:"severity"`
}

type HintRequest struct {
	Method string `json:"method"`
	Hints  []Hint `json:"hints"`
	File   string `json:"file,omitempty"`
}
