package httpapi

import (
	"log/slog"
	"net/http"
	"time"
)

// Middleware wraps an http.Handler to add cross-cutting behavior.
type Middleware func(http.Handler) http.Handler

// statusRecorder wraps http.ResponseWriter to capture the status code.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	// Only the first call wins. Recovery may try to write a 500 after the
	// handler already sent a status; forwarding that would log a superfluous
	// WriteHeader warning for every recovered panic.
	if r.status != 0 {
		return
	}
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func (r *statusRecorder) Status() int {
	if r.status == 0 {
		return http.StatusOK
	}
	return r.status
}

// Recovery recovers from panics in the handler chain, logs them, and returns 500.
func Recovery(logger *slog.Logger) Middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			defer func() {
				if err := recover(); err != nil {
					logger.Error("panic recovered",
						"path", r.URL.Path,
						"error", err)
					writeError(w, http.StatusInternalServerError, "internal_error")
				}
			}()
			next.ServeHTTP(w, r)
		})
	}
}

// RequestLogger logs method, path, status, and duration for each request.
// It has no access to the request body, ensuring sensitive SMS content is never logged.
func RequestLogger(logger *slog.Logger) Middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			rec := &statusRecorder{ResponseWriter: w}

			next.ServeHTTP(rec, r)

			logger.Info("request",
				"method", r.Method,
				"path", r.URL.Path,
				"status", rec.Status(),
				"duration_ms", time.Since(start).Milliseconds())
		})
	}
}

// Chain applies middleware in outermost-first order.
func Chain(h http.Handler, mw ...Middleware) http.Handler {
	for i := len(mw) - 1; i >= 0; i-- {
		h = mw[i](h)
	}
	return h
}
