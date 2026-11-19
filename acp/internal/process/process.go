// Package process manages the ACP subprocess (kiro-cli/opencode).
//
// Handles: spawn, initialize handshake, NDJSON framing, message routing.
package process

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"lg-acp/internal/protocol"
	"log"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"
)

// Process wraps a single ACP subprocess.
type Process struct {
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	nextID int
	mu     sync.Mutex

	// routing
	sessions   map[string]MessageHandler // sessionId -> handler
	pending    map[int]MessageHandler    // rpc id -> handler (for responses)
	sessionsMu sync.RWMutex
	pendingMu  sync.Mutex

	ready       chan struct{} // closed when initialize handshake completes
	initErr     error
	models      *protocol.ModelsInfo
	modelsMu    sync.RWMutex
	kiro        bool     // agent advertised _meta.kiro capabilities (kiro v3)
	antigravity bool     // agent advertised _meta.antigravity
	authMethods []string // auth method IDs from initialize (e.g. "oauth-personal")
}

// MessageHandler receives routed messages for a session.
type MessageHandler func(msg *protocol.Message)

// AgentErrorHandler receives errors the agent logged to stderr for a session.
type AgentErrorHandler func(sessionID, msg string)

// Spawn starts an ACP subprocess, performs the initialize handshake, and returns
// a ready Process. Blocks until handshake completes or fails. onAgentError, if
// set, is called for session errors the agent reports only on stderr.
func Spawn(args []string, clientName string, onAgentError AgentErrorHandler) (*Process, error) {
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Env = append(os.Environ(), "LG_ACP=1")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("stdin pipe: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("stdout pipe: %w", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, fmt.Errorf("stderr pipe: %w", err)
	}

	p := &Process{
		cmd:      cmd,
		stdin:    stdin,
		nextID:   1,
		sessions: make(map[string]MessageHandler),
		pending:  make(map[int]MessageHandler),
		ready:    make(chan struct{}),
	}

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start process: %w", err)
	}

	go p.readLoop(stdout)
	go readStderr(stderr, onAgentError)

	// Send initialize
	id := p.NextID()
	p.pendingMu.Lock()
	p.pending[id] = func(msg *protocol.Message) {
		if msg.Error != nil {
			p.initErr = fmt.Errorf("initialize error: %s", msg.Error.Message)
		} else {
			var res struct {
				AgentCapabilities struct {
					Meta struct {
						Kiro        json.RawMessage `json:"kiro"`
						Antigravity json.RawMessage `json:"antigravity"`
					} `json:"_meta"`
				} `json:"agentCapabilities"`
				AuthMethods []struct {
					ID string `json:"id"`
				} `json:"authMethods"`
			}
			if json.Unmarshal(msg.Result, &res) == nil {
				p.kiro = len(res.AgentCapabilities.Meta.Kiro) > 0
				p.antigravity = len(res.AgentCapabilities.Meta.Antigravity) > 0
				for _, m := range res.AuthMethods {
					p.authMethods = append(p.authMethods, m.ID)
				}
			}
		}
		log.Printf("acp: initialize response received (kiro=%v antigravity=%v authMethods=%v)", p.kiro, p.antigravity, p.authMethods)
		close(p.ready)
	}
	p.pendingMu.Unlock()

	log.Printf("acp: sending initialize to %v", args)
	initReq := protocol.InitializeRequest(id, clientName)
	initData, _ := json.Marshal(initReq)
	log.Printf("acp: initialize payload: %s", string(initData))
	if err := p.Write(initReq); err != nil {
		cmd.Process.Kill()
		return nil, fmt.Errorf("send initialize: %w", err)
	}

	<-p.ready
	log.Printf("acp: process ready (err=%v)", p.initErr)
	if p.initErr != nil {
		cmd.Process.Kill()
		return nil, p.initErr
	}

	// antigravity requires authentication before session/new.
	if p.antigravity && len(p.authMethods) > 0 {
		if err := p.authenticate(p.authMethods[0]); err != nil {
			cmd.Process.Kill()
			return nil, fmt.Errorf("authenticate: %w", err)
		}
	}

	return p, nil
}

// NextID returns the next JSON-RPC id (thread-safe).
func (p *Process) NextID() int {
	p.mu.Lock()
	id := p.nextID
	p.nextID++
	p.mu.Unlock()
	return id
}

// Write sends a JSON-RPC message to the subprocess stdin.
func (p *Process) Write(msg protocol.Message) error {
	data, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	p.mu.Lock()
	_, err = fmt.Fprintf(p.stdin, "%s\n", data)
	p.mu.Unlock()
	return err
}

// TrackResponse registers a handler for a specific RPC response id.
func (p *Process) TrackResponse(id int, handler MessageHandler) {
	p.pendingMu.Lock()
	p.pending[id] = handler
	p.pendingMu.Unlock()
}

// RegisterSession registers a handler for a session id.
func (p *Process) RegisterSession(sessionID string, handler MessageHandler) {
	p.sessionsMu.Lock()
	p.sessions[sessionID] = handler
	p.sessionsMu.Unlock()
}

// UnregisterSession removes a session handler.
func (p *Process) UnregisterSession(sessionID string) {
	p.sessionsMu.Lock()
	delete(p.sessions, sessionID)
	p.sessionsMu.Unlock()
}

// IsKiro reports whether the agent is kiro v3, which uses kiro's extension
// methods (_kiro/*).
func (p *Process) IsKiro() bool {
	return p.kiro
}

// Isantigravity reports whether the agent is antigravity.
func (p *Process) Isantigravity() bool {
	return p.antigravity
}

// authenticate sends the ACP authenticate request and blocks until the response
// arrives. antigravity reuses the existing agy CLI login state.
func (p *Process) authenticate(methodID string) error {
	done := make(chan error, 1)
	id := p.NextID()
	p.TrackResponse(id, func(msg *protocol.Message) {
		if msg.Error != nil {
			done <- fmt.Errorf("%s", msg.Error.Detail())
		} else {
			done <- nil
		}
	})
	log.Printf("acp: sending authenticate methodId=%s", methodID)
	if err := p.Write(protocol.AuthenticateRequest(id, methodID)); err != nil {
		return err
	}
	// A cached login answers immediately; a fresh OAuth sign-in may need the
	// browser. Never block lg forever on it.
	select {
	case err := <-done:
		return err
	case <-time.After(2 * time.Minute):
		return fmt.Errorf("timed out waiting for sign-in (run `agy` once to log in)")
	}
}

// Models returns the latest models info reported by the agent, if any.
func (p *Process) Models() *protocol.ModelsInfo {
	p.modelsMu.RLock()
	defer p.modelsMu.RUnlock()
	return p.models
}

// SetModels stores models info (called by session manager on first session/new).
func (p *Process) SetModels(m *protocol.ModelsInfo) {
	p.modelsMu.Lock()
	defer p.modelsMu.Unlock()
	if p.models == nil {
		p.models = m
	}
}

// ReplaceModels overwrites the models info. opencode 2.x sends its real,
// routable model list in config_option_update after session/new.
func (p *Process) ReplaceModels(m *protocol.ModelsInfo) {
	p.modelsMu.Lock()
	defer p.modelsMu.Unlock()
	p.models = m
}

// Terminate kills the subprocess and its process group.
func (p *Process) Terminate() {
	if p.cmd != nil && p.cmd.Process != nil {
		// Kill the entire process group
		syscall.Kill(-p.cmd.Process.Pid, syscall.SIGKILL)
	}
}

func (p *Process) readLoop(r io.Reader) {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 1024*1024), 10*1024*1024)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		log.Printf("acp: recv: %s", string(line[:min(len(line), 500)]))
		var msg protocol.Message
		if err := json.Unmarshal(line, &msg); err != nil {
			log.Printf("acp: bad json: %v", err)
			continue
		}
		p.route(&msg)
	}
}

// readStderr drains the agent's stderr so it never blocks on a full pipe, and
// reports session errors that never reach the protocol stream.
func readStderr(r io.Reader, onAgentError AgentErrorHandler) {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		sid, msg, ok := protocol.ParseAgentError(scanner.Text())
		if !ok {
			continue
		}
		log.Printf("acp: agent error session=%s: %s", sid, msg)
		if onAgentError != nil {
			onAgentError(sid, msg)
		}
	}
}

func (p *Process) route(msg *protocol.Message) {
	// Response — check pending map
	if msg.IsResponse() && msg.ID != nil {
		p.pendingMu.Lock()
		handler, ok := p.pending[msg.ID.IntVal()]
		if ok {
			delete(p.pending, msg.ID.IntVal())
		}
		p.pendingMu.Unlock()
		if ok {
			handler(msg)
			return
		}
	}

	// Notification or request — route by sessionId in params
	if msg.Params != nil {
		var peek struct {
			SessionID string `json:"sessionId"`
		}
		if json.Unmarshal(msg.Params, &peek) == nil && peek.SessionID != "" {
			p.sessionsMu.RLock()
			handler, ok := p.sessions[peek.SessionID]
			p.sessionsMu.RUnlock()
			if ok {
				handler(msg)
				return
			}
		}
	}

	// Fallback: route to first registered session
	p.sessionsMu.RLock()
	for _, handler := range p.sessions {
		p.sessionsMu.RUnlock()
		handler(msg)
		return
	}
	p.sessionsMu.RUnlock()
	log.Printf("acp: unrouted message: method=%s id=%v", msg.Method, msg.ID)
	if msg.IsRequest() {
		p.Write(protocol.MethodNotFoundResponse(msg.ID, msg.Method))
	}
}
