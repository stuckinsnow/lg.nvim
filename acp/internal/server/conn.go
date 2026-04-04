package server

import (
	"bufio"
	"encoding/json"
	"lg-acp/internal/protocol"
	"lg-acp/internal/session"
	"log"
	"net"
	"os"
	"sync"
)

// conn handles a single Lua client connection.
type conn struct {
	net.Conn
	mu       sync.Mutex
	sessions []*session.Session
	srv      *Server
}

func newConn(nc net.Conn, srv *Server) *conn {
	return &conn{Conn: nc, srv: srv}
}

func (c *conn) writeLine(v any) {
	data, _ := json.Marshal(v)
	c.mu.Lock()
	c.Conn.Write(append(data, '\n'))
	c.mu.Unlock()
}

func (c *conn) streamEvents(sess *session.Session) {
	for ev := range sess.Events() {
		c.writeLine(ev)
	}
}

func (c *conn) serve() {
	defer c.Close()

	scanner := bufio.NewScanner(c.Conn)
	scanner.Buffer(make([]byte, 0, 1024*1024), 10*1024*1024)

	for scanner.Scan() {
		var req Request
		if err := json.Unmarshal(scanner.Bytes(), &req); err != nil {
			c.writeLine(Response{Error: "bad json"})
			continue
		}
		c.handle(req)
	}
}

func (c *conn) handle(req Request) {
	mgr := c.srv.mgr

	switch req.Method {
	case "create_session":
		cwd := req.CWD
		if cwd == "" {
			cwd, _ = os.Getwd()
		}
		if len(req.MCPServers) > 0 {
			var servers map[string]any
			if err := json.Unmarshal(req.MCPServers, &servers); err == nil && len(servers) > 0 {
				mgr.SetMCPServers(servers)
			}
		}
		log.Printf("acp: create_session cwd=%s", cwd)
		sess, err := mgr.CreateSession(cwd)
		if err != nil {
			log.Printf("acp: create_session error: %v", err)
			c.writeLine(Response{Error: err.Error()})
			return
		}
		log.Printf("acp: waiting for session ready event...")
		ev := <-sess.Events()
		log.Printf("acp: got event type=%s", ev.Type)
		if ev.Type == "error" {
			c.writeLine(Response{Error: ev.Error})
			return
		}
		var result struct {
			Models json.RawMessage `json:"models"`
		}
		if json.Unmarshal(ev.Data, &result) == nil && result.Models != nil {
			c.writeLine(Response{OK: true, SessionID: sess.ID, Models: result.Models})
		} else {
			c.writeLine(Response{OK: true, SessionID: sess.ID})
		}
		c.mu.Lock()
		c.sessions = append(c.sessions, sess)
		c.mu.Unlock()
		go c.streamEvents(sess)

	case "prompt":
		sess := mgr.GetSession(req.SessionID)
		if sess == nil {
			c.writeLine(Response{Error: "unknown session"})
			return
		}
		if err := sess.Prompt(req.Prompt, func() {}); err != nil {
			c.writeLine(Response{Error: err.Error()})
			return
		}
		c.writeLine(Response{OK: true})

	case "set_mode":
		sess := mgr.GetSession(req.SessionID)
		if sess == nil {
			c.writeLine(Response{Error: "unknown session"})
			return
		}
		if err := sess.SetMode(req.ModeID); err != nil {
			c.writeLine(Response{Error: err.Error()})
			return
		}
		c.writeLine(Response{OK: true})

	case "set_model":
		sess := mgr.GetSession(req.SessionID)
		if sess == nil {
			c.writeLine(Response{Error: "unknown session"})
			return
		}
		if err := sess.SetModel(req.ModelID); err != nil {
			c.writeLine(Response{Error: err.Error()})
			return
		}
		c.writeLine(Response{OK: true})

	case "cancel":
		if sess := mgr.GetSession(req.SessionID); sess != nil {
			sess.Cancel()
		}
		c.writeLine(Response{OK: true})

	case "destroy_session":
		if sess := mgr.GetSession(req.SessionID); sess != nil {
			sess.Cancel()
			mgr.RemoveSession(req.SessionID)
		}
		c.writeLine(Response{OK: true})

	case "respond_permission":
		if sess := mgr.GetSession(req.SessionID); sess != nil {
			sess.RespondPermission(req.RPCID, req.OptionID)
		}
		c.writeLine(Response{OK: true})

	case "get_models":
		models := mgr.Models()
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
		data, err := listSessions(c.srv.provider, cwd)
		if err != nil {
			c.writeLine(Response{Error: err.Error()})
			return
		}
		c.writeLine(Response{OK: true, Data: data})

	case "delete_session":
		if req.SessionID == "" {
			c.writeLine(Response{Error: "missing session_id"})
			return
		}
		log.Printf("acp: delete_session id=%s", req.SessionID)
		if err := deleteSession(c.srv.provider, req.SessionID); err != nil {
			c.writeLine(Response{Error: err.Error()})
			return
		}
		c.writeLine(Response{OK: true})

	case "load_session":
		cwd := req.CWD
		if cwd == "" {
			cwd, _ = os.Getwd()
		}
		if req.SessionID == "" {
			c.writeLine(Response{Error: "missing session_id"})
			return
		}
		log.Printf("acp: load_session id=%s", req.SessionID)
		sess, err := mgr.LoadSession(req.SessionID, cwd)
		if err != nil {
			c.writeLine(Response{Error: err.Error()})
			return
		}
		c.writeLine(Response{OK: true, SessionID: sess.ID})
		c.mu.Lock()
		c.sessions = append(c.sessions, sess)
		c.mu.Unlock()
		go c.streamEvents(sess)

	case "status":
		c.writeLine(Response{OK: true, Active: len(mgr.Sessions())})

	case "execute_command":
		sess := mgr.GetSession(req.SessionID)
		if sess == nil {
			c.writeLine(Response{Error: "unknown session"})
			return
		}
		if req.Command == "" {
			c.writeLine(Response{Error: "missing command"})
			return
		}
		if err := sess.ExecuteCommand(req.Command, func(msg *protocol.Message) {
			if msg.Error != nil {
				c.writeLine(Response{Error: msg.Error.Message})
			} else {
				c.writeLine(Response{OK: true})
			}
		}); err != nil {
			c.writeLine(Response{Error: err.Error()})
		}

	case "terminate":
		mgr.Terminate()
		c.writeLine(Response{OK: true})

	default:
		c.writeLine(Response{Error: "unknown method: " + req.Method})
	}
}
