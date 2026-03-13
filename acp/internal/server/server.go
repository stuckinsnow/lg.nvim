// Package server implements the unix socket API that Neovim (Lua) talks to.
//
// One connection receives ALL session events. Lua filters by session_id.
//
// Requests:
//   {"method":"create_session","cwd":"/path"}
//   {"method":"prompt","session_id":"...","prompt":[...]}
//   {"method":"set_mode","session_id":"...","mode_id":"lg"}
//   {"method":"set_model","session_id":"...","model_id":"claude-sonnet-4-5"}
//   {"method":"cancel","session_id":"..."}
//   {"method":"destroy_session","session_id":"..."}
//   {"method":"respond_permission","session_id":"...","rpc_id":5,"option_id":"once"}
//   {"method":"get_models"}
//   {"method":"status"}
//   {"method":"terminate"}
package server

import (
	"bufio"
	"encoding/json"
	"fmt"
	"lg-acp/internal/session"
	"log"
	"net"
	"os"
	"sync"
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
}

func New(mgr *session.Manager, sockPath string) *Server {
	return &Server{mgr: mgr, sockPath: sockPath}
}

func (s *Server) Start() error {
	os.Remove(s.sockPath)
	ln, err := net.Listen("unix", s.sockPath)
	if err != nil {
		return fmt.Errorf("listen %s: %w", s.sockPath, err)
	}
	s.listener = ln
	log.Printf("acp: listening on %s", s.sockPath)
	for {
		conn, err := ln.Accept()
		if err != nil {
			return nil
		}
		go s.handleConn(conn)
	}
}

func (s *Server) Stop() {
	if s.listener != nil {
		s.listener.Close()
	}
	os.Remove(s.sockPath)
}

// conn holds the write mutex and a list of sessions whose events we're streaming.
type conn struct {
	net.Conn
	mu       sync.Mutex
	sessions []*session.Session // all sessions created on this connection
}

func (c *conn) writeLine(v any) {
	data, _ := json.Marshal(v)
	c.mu.Lock()
	c.Conn.Write(append(data, '\n'))
	c.mu.Unlock()
}

// streamEvents drains a session's event channel and writes to the connection.
func (c *conn) streamEvents(sess *session.Session) {
	for ev := range sess.Events() {
		c.writeLine(ev)
	}
}

func (s *Server) handleConn(nc net.Conn) {
	c := &conn{Conn: nc}
	defer func() {
		c.Close()
	}()

	scanner := bufio.NewScanner(nc)
	scanner.Buffer(make([]byte, 0, 1024*1024), 10*1024*1024)

	for scanner.Scan() {
		var req Request
		if err := json.Unmarshal(scanner.Bytes(), &req); err != nil {
			c.writeLine(Response{Error: "bad json"})
			continue
		}

		switch req.Method {
		case "create_session":
			cwd := req.CWD
			if cwd == "" {
				cwd, _ = os.Getwd()
			}
			if len(req.MCPServers) > 0 {
				var servers map[string]any
				if err := json.Unmarshal(req.MCPServers, &servers); err == nil && len(servers) > 0 {
					s.mgr.SetMCPServers(servers)
				}
			}
			log.Printf("acp: create_session cwd=%s", cwd)
			sess, err := s.mgr.CreateSession(cwd)
			if err != nil {
				log.Printf("acp: create_session error: %v", err)
				c.writeLine(Response{Error: err.Error()})
				continue
			}
			log.Printf("acp: waiting for session ready event...")
			// Wait for ready
			ev := <-sess.Events()
			log.Printf("acp: got event type=%s", ev.Type)
			if ev.Type == "error" {
				c.writeLine(Response{Error: ev.Error})
				continue
			}
			// Extract just the models from the full session/new result
			var result struct {
				Models json.RawMessage `json:"models"`
			}
			if json.Unmarshal(ev.Data, &result) == nil && result.Models != nil {
				c.writeLine(Response{OK: true, SessionID: sess.ID, Models: result.Models})
			} else {
				c.writeLine(Response{OK: true, SessionID: sess.ID})
			}
			// Stream all future events for this session on this connection
			c.mu.Lock()
			c.sessions = append(c.sessions, sess)
			c.mu.Unlock()
			go c.streamEvents(sess)

		case "prompt":
			sess := s.mgr.GetSession(req.SessionID)
			if sess == nil {
				c.writeLine(Response{Error: "unknown session"})
				continue
			}
			if err := sess.Prompt(req.Prompt, func() {}); err != nil {
				c.writeLine(Response{Error: err.Error()})
				continue
			}
			c.writeLine(Response{OK: true})

		case "set_mode":
			sess := s.mgr.GetSession(req.SessionID)
			if sess == nil {
				c.writeLine(Response{Error: "unknown session"})
				continue
			}
			if err := sess.SetMode(req.ModeID); err != nil {
				c.writeLine(Response{Error: err.Error()})
				continue
			}
			c.writeLine(Response{OK: true})

		case "set_model":
			sess := s.mgr.GetSession(req.SessionID)
			if sess == nil {
				c.writeLine(Response{Error: "unknown session"})
				continue
			}
			if err := sess.SetModel(req.ModelID); err != nil {
				c.writeLine(Response{Error: err.Error()})
				continue
			}
			c.writeLine(Response{OK: true})

		case "cancel":
			if sess := s.mgr.GetSession(req.SessionID); sess != nil {
				sess.Cancel()
			}
			c.writeLine(Response{OK: true})

		case "destroy_session":
			if sess := s.mgr.GetSession(req.SessionID); sess != nil {
				sess.Cancel()
				s.mgr.RemoveSession(req.SessionID)
			}
			c.writeLine(Response{OK: true})

		case "respond_permission":
			if sess := s.mgr.GetSession(req.SessionID); sess != nil {
				sess.RespondPermission(req.RPCID, req.OptionID)
			}
			c.writeLine(Response{OK: true})

		case "get_models":
			models := s.mgr.Models()
			if models != nil {
				data, _ := json.Marshal(models)
				c.writeLine(Response{OK: true, Models: data})
			} else {
				c.writeLine(Response{OK: true})
			}

		case "list_sessions":
			cwd := req.CWD
			if cwd == "" {
				cwd, _ = os.Getwd()
			}
			log.Printf("acp: list_sessions cwd=%s", cwd)
			result, err := s.mgr.ListSessions(cwd)
			if err != nil {
				c.writeLine(Response{Error: err.Error()})
				continue
			}
			c.writeLine(Response{OK: true, Data: result})

		case "load_session":
			cwd := req.CWD
			if cwd == "" {
				cwd, _ = os.Getwd()
			}
			if req.SessionID == "" {
				c.writeLine(Response{Error: "missing session_id"})
				continue
			}
			log.Printf("acp: load_session id=%s", req.SessionID)
			sess, err := s.mgr.LoadSession(req.SessionID, cwd)
			if err != nil {
				c.writeLine(Response{Error: err.Error()})
				continue
			}
			c.writeLine(Response{OK: true, SessionID: sess.ID})
			c.mu.Lock()
			c.sessions = append(c.sessions, sess)
			c.mu.Unlock()
			go c.streamEvents(sess)

		case "status":
			c.writeLine(Response{OK: true, Active: len(s.mgr.Sessions())})

		case "terminate":
			s.mgr.Terminate()
			c.writeLine(Response{OK: true})

		default:
			c.writeLine(Response{Error: "unknown method: " + req.Method})
		}
	}
}
