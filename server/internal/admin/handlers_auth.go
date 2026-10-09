package admin

import (
	"encoding/json"
	"net/http"

	"github.com/ahmedsadman/pawlet/server/internal/clientip"
)

type loginRequest struct {
	Password string `json:"password"`
}

func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	ip := clientip.From(r, s.trustedProxy)

	// Reserve a login slot and count it as a failure up front.
	a, ok := s.limiter.begin(ip)
	if !ok {
		s.logger.Warn("admin login rate limited", "ip", ip)
		writeError(w, http.StatusTooManyRequests, "rate_limited")
		return
	}

	// Cap concurrent argon2id verifications to bound peak memory (64 MiB each).
	select {
	case s.verifySlots <- struct{}{}:
		defer func() { <-s.verifySlots }()
	default:
		writeError(w, http.StatusTooManyRequests, "rate_limited")
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 4<<10)
	var req loginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Password == "" {
		writeError(w, http.StatusBadRequest, "bad_request")
		return
	}

	ok, err := VerifyPassword(s.passwordHash, req.Password)
	if err != nil {
		s.fail(w, "verify password", err)
		return
	}
	if !ok {
		// Slot already counted as a failure; do nothing extra.
		s.logger.Warn("admin login failed", "ip", ip)
		writeError(w, http.StatusUnauthorized, "invalid_password")
		return
	}

	// Password correct; clear the failure.
	s.limiter.succeed(a)
	if err := s.sessions.start(w); err != nil {
		s.fail(w, "start session", err)
		return
	}
	s.logger.Info("admin login", "ip", ip)
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) logout(w http.ResponseWriter, _ *http.Request) {
	s.sessions.end(w)
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) me(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusNoContent)
}
