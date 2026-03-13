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
	"os/exec"
	"sync"
)

// Process wraps a single ACP subprocess.
type Process struct {
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	nextID int
	mu     sync.Mutex

	// routing
	sessions   map[string]MessageHandler   // sessionId -> handler
	pending    map[int]MessageHandler       // rpc id -> handler (for responses)
	sessionsMu sync.RWMutex
	pendingMu  sync.Mutex

	ready    chan struct{} // closed when initialize handshake completes
	initErr  error
	models   *protocol.ModelsInfo
}

// MessageHandler receives routed messages for a session.
type MessageHandler func(msg *protocol.Message)

// Spawn starts an ACP subprocess, performs the initialize handshake, and returns
// a ready Process. Blocks until handshake completes or fails.
func Spawn(args []string, clientName string) (*Process, error) {
	cmd := exec.Command(args[0], args[1:]...)

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("stdin pipe: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("stdout pipe: %w", err)
	}
	cmd.Stderr = io.Discard

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

	// Send initialize
	id := p.NextID()
	p.pendingMu.Lock()
	p.pending[id] = func(msg *protocol.Message) {
		if msg.Error != nil {
			p.initErr = fmt.Errorf("initialize error: %s", msg.Error.Message)
		}
		log.Printf("acp: initialize response received")
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

// Models returns the models info from the first session creation, if available.
func (p *Process) Models() *protocol.ModelsInfo {
	return p.models
}

// SetModels stores models info (called by session manager on first session/new).
func (p *Process) SetModels(m *protocol.ModelsInfo) {
	if p.models == nil {
		p.models = m
	}
}

// Terminate kills the subprocess.
func (p *Process) Terminate() {
	if p.cmd != nil && p.cmd.Process != nil {
		p.cmd.Process.Kill()
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
		log.Printf("acp: recv: %s", string(line[:min(len(line), 200)]))
		var msg protocol.Message
		if err := json.Unmarshal(line, &msg); err != nil {
			log.Printf("acp: bad json: %v", err)
			continue
		}
		p.route(&msg)
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
}
