// Package server implements the unix socket API that Neovim (Lua) talks to.
package server

import (
	"fmt"
	"lg/internal/acp/session"
	"log"
	"net"
	"os"
	"time"
)

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
