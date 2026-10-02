// Package httpapi exposes the service's HTTP surface.
package httpapi

import "net/http"

// Handlers collects the per-endpoint handlers the router dispatches to.
type Handlers struct {
	Session  *SessionHandler
	Classify *ClassifyHandler
	Bundle   *BundleHandler
}

// NewRouter builds the route table.
func NewRouter(h Handlers) http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("GET /v1/challenge", h.Session.Challenge)
	mux.HandleFunc("POST /v1/session", h.Session.Session)
	mux.HandleFunc("POST /v1/classify", h.Classify.Classify)
	mux.HandleFunc("GET /v1/prompt-bundle", h.Bundle.Bundle)

	return mux
}
