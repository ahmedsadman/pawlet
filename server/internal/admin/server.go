package admin

import (
	"context"
	"io/fs"
	"log/slog"
	"net"
	"net/http"
	"time"

	"github.com/ahmedsadman/pawlet/server/internal/store"
)

// maxConcurrentVerifies caps simultaneous argon2id verifications. Each uses
// 64 MiB, so 2 concurrent = 128 MiB peak.
const maxConcurrentVerifies = 2

// Options configures a Server.
type Options struct {
	Store         *store.Store
	PasswordHash  string
	SessionSecret []byte
	TrustedProxy  *net.IPNet   // nil: use the peer address
	Logger        *slog.Logger // nil: slog.Default()
	Now           func() time.Time
	Web           fs.FS // nil: the SPA embedded at build time
}

// Server is the admin HTTP service.
type Server struct {
	store        *store.Store
	passwordHash string
	sessions     *sessions
	limiter      *loginLimiter
	verifySlots  chan struct{}
	trustedProxy *net.IPNet
	logger       *slog.Logger
	now          func() time.Time
	web          fs.FS
}

// New builds a Server.
func New(o Options) *Server {
	if o.Now == nil {
		o.Now = time.Now
	}
	if o.Logger == nil {
		o.Logger = slog.Default()
	}
	if o.Web == nil {
		o.Web = embeddedWeb()
	}
	return &Server{
		store:        o.Store,
		passwordHash: o.PasswordHash,
		sessions:     newSessions(o.SessionSecret, o.Now),
		limiter:      newLoginLimiter(o.Now),
		verifySlots:  make(chan struct{}, maxConcurrentVerifies),
		trustedProxy: o.TrustedProxy,
		logger:       o.Logger,
		now:          o.Now,
		web:          o.Web,
	}
}

// Handler builds the route table.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.health)
	mux.HandleFunc("POST /api/login", sameOriginJSON(s.login))
	mux.HandleFunc("POST /api/logout", sameOriginJSON(s.logout))
	mux.HandleFunc("GET /api/me", s.requireSession(s.me))
	mux.HandleFunc("GET /api/overview", s.requireSession(s.overview))
	mux.HandleFunc("GET /api/installs", s.requireSession(s.installs))
	mux.HandleFunc("GET /api/installs/{hash}", s.requireSession(s.installDetail))
	mux.HandleFunc("POST /api/installs/{hash}/ban", sameOriginJSON(s.requireSession(s.ban)))
	mux.HandleFunc("POST /api/installs/{hash}/unban", sameOriginJSON(s.requireSession(s.unban)))
	mux.HandleFunc("GET /api/engagement", s.requireSession(s.engagement))
	mux.HandleFunc("GET /api/reliability", s.requireSession(s.reliability))
	mux.HandleFunc("GET /api/fleet", s.requireSession(s.fleet))
	mux.HandleFunc("/api/", func(w http.ResponseWriter, _ *http.Request) {
		writeError(w, http.StatusNotFound, "not_found")
	})
	mux.Handle("/", s.spa())
	return securityHeaders(mux)
}

func (s *Server) requireSession(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.sessions.valid(r) {
			writeError(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		next(w, r)
	}
}

// fail logs an unexpected error and answers with a bare 500.
func (s *Server) fail(w http.ResponseWriter, what string, err error) {
	s.logger.Error("admin request failed", "op", what, "error", err)
	writeError(w, http.StatusInternalServerError, "internal")
}

func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := s.store.Ping(ctx); err != nil {
		s.logger.Error("admin health check failed", "error", err)
		writeError(w, http.StatusServiceUnavailable, "database_unavailable")
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = w.Write([]byte("ok"))
}
