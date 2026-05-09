// Package server implements the unix socket API that Neovim (Lua) talks to.
package server

import (
	"encoding/json"
	"fmt"
	"lg-acp/internal/session"
	"log"
	"net"
	"os"
	"sync"
	"time"
)

type Request struct {
	Method      string          `json:"method"`
	CWD         string          `json:"cwd,omitempty"`
	SessionID   string          `json:"session_id,omitempty"`
	Prompt      json.RawMessage `json:"prompt,omitempty"`
	ModeID      string          `json:"mode_id,omitempty"`
	LogicalMode string          `json:"logical_mode,omitempty"`
	ModelID     string          `json:"model_id,omitempty"`
	OptionID    string          `json:"option_id,omitempty"`
	RPCID       int             `json:"rpc_id,omitempty"`
	MCPServers  json.RawMessage `json:"mcp_servers,omitempty"`
	Command     string          `json:"command,omitempty"`
	Args        json.RawMessage `json:"args,omitempty"`
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

func New(mgr *session.Manager, sockPath, provider string) *Server {
	return &Server{mgr: mgr, sockPath: sockPath, provider: provider}
}

func (s *Server) Start() error {
	os.Remove(s.sockPath)
	ln, err := net.Listen("unix", s.sockPath)
	if err != nil {
		return fmt.Errorf("listen %s: %w", s.sockPath, err)
	}
	s.listener = ln
	s.startIdleTimer()
	log.Printf("acp: listening on %s", s.sockPath)
	for {
		nc, err := ln.Accept()
		if err != nil {
			return nil
		}
		s.addConn()
		go func() {
			newConn(nc, s).serve()
			s.removeConn()
		}()
	}
}

const idleTimeout = 2 * time.Minute

func (s *Server) startIdleTimer() {
	s.idleTimer = time.AfterFunc(idleTimeout, func() {
		log.Printf("acp: no connections for %v, shutting down", idleTimeout)
		s.mgr.Terminate()
		s.Stop()
		os.Exit(0)
	})
}

func (s *Server) addConn() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.connCount++
	if s.idleTimer != nil {
		s.idleTimer.Stop()
	}
}

func (s *Server) removeConn() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.connCount--
	if s.connCount <= 0 {
		s.connCount = 0
		s.startIdleTimer()
	}
}

func (s *Server) Stop() {
	if s.listener != nil {
		s.listener.Close()
	}
	os.Remove(s.sockPath)
}
