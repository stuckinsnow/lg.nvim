package server

import (
	"encoding/json"
	"net"
	"sync"
	"time"

	"lg/internal/acp/session"
)

type Request struct {
	Method     string          `json:"method"`
	CWD        string          `json:"cwd,omitempty"`
	SessionID  string          `json:"session_id,omitempty"`
	Prompt     json.RawMessage `json:"prompt,omitempty"`
	ModeID     string          `json:"mode_id,omitempty"`
	ModelID    string          `json:"model_id,omitempty"`
	OptionID   string          `json:"option_id,omitempty"`
	RPCID      int             `json:"rpc_id,omitempty"`
	MCPServers json.RawMessage `json:"mcp_servers,omitempty"`
	Command    string          `json:"command,omitempty"`
	Args       json.RawMessage `json:"args,omitempty"`
	Reason     string          `json:"reason,omitempty"`
}

type Response struct {
	OK        bool            `json:"ok"`
	SessionID string          `json:"session_id,omitempty"`
	Models    json.RawMessage `json:"models,omitempty"`
	Data      json.RawMessage `json:"data,omitempty"`
	Error     string          `json:"error,omitempty"`
	Active    int             `json:"active,omitempty"`
}

type Server struct {
	mgr      *session.Manager
	listener net.Listener
	sockPath string
	provider string

	mu        sync.Mutex
	connCount int
	idleTimer *time.Timer
}

type sessionEntry struct {
	ID      string `json:"id"`
	Title   string `json:"title"`
	Date    string `json:"date"`
	Preview string `json:"preview"`
}
