package httpapi

import (
	"encoding/json"
	"net/http"
	"strconv"
	"time"
)

// errorBody is the single error shape every endpoint returns. It deliberately
// carries no detail about why verification failed: precise reasons go to the
// log, not to the caller.
type errorBody struct {
	Error string `json:"error"`
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func writeError(w http.ResponseWriter, status int, code string) {
	writeJSON(w, status, errorBody{Error: code})
}

// writeRateLimited emits 429 with the hints the client already knows how to
// read, so its existing backoff needs no change.
func writeRateLimited(w http.ResponseWriter, retryAfter time.Duration, resetAtEpochMs int64) {
	// A negative duration would format as a negative header value the client
	// cannot interpret.
	if retryAfter > 0 {
		w.Header().Set("Retry-After", strconv.Itoa(int(retryAfter.Seconds())))
	}
	if resetAtEpochMs > 0 {
		w.Header().Set("X-RateLimit-Reset", strconv.FormatInt(resetAtEpochMs, 10))
	}
	writeError(w, http.StatusTooManyRequests, "rate_limited")
}
