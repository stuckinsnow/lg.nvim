package protocol

import (
	"encoding/json"
	"testing"
)

func TestRPCErrorDetailPrefersStringData(t *testing.T) {
	raw := `{"code":-32603,"message":"Internal error","data":"The model 'claude-sonnet-4-6' is not available. Please use '/model' to select a different model and try again."}`
	var e RPCError
	if err := json.Unmarshal([]byte(raw), &e); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	got := e.Detail()
	want := "The model 'claude-sonnet-4-6' is not available. Please use '/model' to select a different model and try again."
	if got != want {
		t.Fatalf("Detail() = %q, want %q", got, want)
	}
}

func TestRPCErrorDetailFallsBackToMessage(t *testing.T) {
	for name, raw := range map[string]string{
		"no data":    `{"code":-1,"message":"boom"}`,
		"null data":  `{"code":-1,"message":"boom","data":null}`,
		"empty data": `{"code":-1,"message":"boom","data":{}}`,
	} {
		var e RPCError
		if err := json.Unmarshal([]byte(raw), &e); err != nil {
			t.Fatalf("%s: unmarshal: %v", name, err)
		}
		if got := e.Detail(); got != "boom" {
			t.Fatalf("%s: Detail() = %q, want %q", name, got, "boom")
		}
	}
}

func TestRPCErrorDetailAppendsStructuredData(t *testing.T) {
	var e RPCError
	if err := json.Unmarshal([]byte(`{"code":-1,"message":"boom","data":{"why":"nope"}}`), &e); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	want := `boom: {"why":"nope"}`
	if got := e.Detail(); got != want {
		t.Fatalf("Detail() = %q, want %q", got, want)
	}
}

func TestRPCErrorDetailNil(t *testing.T) {
	var e *RPCError
	if got := e.Detail(); got != "" {
		t.Fatalf("Detail() = %q, want empty", got)
	}
}
