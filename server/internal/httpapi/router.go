// Package httpapi exposes the service's HTTP surface.
package httpapi

import (
	"context"
	"log/slog"
	"net/http"
	"time"
)

// HealthChecker reports whether a dependency is usable. Declared here because
// this package consumes it, so the health route can be tested without a
// database.
type HealthChecker interface {
	Ping(ctx context.Context) error
}

// healthTimeout bounds the probe so a locked or stalled database cannot hang
// the liveness check.
const healthTimeout = 2 * time.Second

// Handlers collects the per-endpoint handlers the router dispatches to.
type Handlers struct {
	Session    *SessionHandler
	Classify   *ClassifyHandler
	ModelStats *ModelStatsHandler
	Bundle     *BundleHandler
	Health     HealthChecker
	Logger     *slog.Logger
}

// NewRouter builds the route table.
func NewRouter(h Handlers) http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /healthz", healthHandler(h.Health, h.Logger))
	mux.HandleFunc("GET /v1/challenge", h.Session.Challenge)
	mux.HandleFunc("POST /v1/session", h.Session.Session)
	mux.HandleFunc("POST /v1/classify", h.Classify.Classify)
	mux.HandleFunc("POST /v1/model-stats", h.ModelStats.ModelStats)
	mux.HandleFunc("GET /v1/prompt-bundle", h.Bundle.Bundle)

	return mux
}

// healthHandler reports 200 only when the database answers. A static "ok"
// would stay green through the failure that matters most here — the data
// volume being unreadable or unwritable.
func healthHandler(checker HealthChecker, logger *slog.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if checker != nil {
			ctx, cancel := context.WithTimeout(r.Context(), healthTimeout)
			defer cancel()

			if err := checker.Ping(ctx); err != nil {
				if logger != nil {
					logger.Error("health check failed", "err", err)
				}
				writeError(w, http.StatusServiceUnavailable, "database_unavailable")
				return
			}
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok"))
	}
}
