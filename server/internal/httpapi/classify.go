package httpapi

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/ahmedsadman/pawlet/server/internal/llm"
	"github.com/ahmedsadman/pawlet/server/internal/quota"
	"github.com/ahmedsadman/pawlet/server/internal/store"
	"github.com/ahmedsadman/pawlet/server/internal/token"
)

// Classifier performs one fused classify+extract call. Declared here because
// this package consumes it, so handler tests need no network.
type Classifier interface {
	Classify(ctx any, in llm.Request) (llm.Response, error)
}

// ClassifyHandler proxies classify calls to the LLM behind session auth and quota.
type ClassifyHandler struct {
	Classifier Classifier
	Issuer     *token.Issuer
	Store      *store.Store
	Limiter    *quota.Limiter
	Now        func() time.Time
	Logger     *slog.Logger
}

type classifyRequest struct {
	Sender   string `json:"sender"`
	Content  string `json:"content"`
	Currency string `json:"currency"`
}

var inputCurrencyPattern = regexp.MustCompile(`^[A-Za-z]{3}$`)

// Classify authenticates the caller, enforces quota, and proxies the SMS
// classification to the LLM. Privacy is load-bearing: message content is never
// logged or persisted.
func (h *ClassifyHandler) Classify(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	start := h.Now()

	// 1. Authenticate: extract and verify the bearer token.
	authHeader := r.Header.Get("Authorization")
	if authHeader == "" {
		h.Logger.Warn("missing authorization header")
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}

	// TrimPrefix returns the input unchanged if the prefix is absent, so we
	// check against the original to detect a malformed header.
	rawToken := strings.TrimPrefix(authHeader, "Bearer ")
	if rawToken == authHeader {
		h.Logger.Warn("malformed authorization header")
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}

	installHash, err := h.Issuer.Verify(rawToken, h.Now())
	if err != nil {
		h.Logger.Warn("token verification failed",
			"installHash", func() string {
				if len(installHash) >= 8 {
					return installHash[:8]
				}
				return "unknown"
			}(),
			"error", err)
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}

	// Look up the install. A validly signed token for an install we never
	// recorded is stale — make the client re-attest rather than trusting it.
	install, err := h.Store.Install(ctx, installHash)
	if errors.Is(err, store.ErrNotFound) {
		h.Logger.Warn("token for unknown install",
			"installHash", installHash[:8])
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if err != nil {
		h.Logger.Error("failed to read install",
			"installHash", installHash[:8],
			"error", err)
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	if install.Banned {
		h.Logger.Warn("banned install attempted classify",
			"installHash", installHash[:8],
			"banReason", install.BanReason)
		writeError(w, http.StatusForbidden, "banned")
		return
	}

	// 2. Decode and validate the request body.
	r.Body = http.MaxBytesReader(w, r.Body, 8<<10)

	var req classifyRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		h.Logger.Warn("malformed classify request",
			"installHash", installHash[:8],
			"error", err)
		writeError(w, http.StatusBadRequest, "bad_request")
		return
	}

	if req.Content == "" {
		h.Logger.Warn("empty content",
			"installHash", installHash[:8])
		writeError(w, http.StatusBadRequest, "bad_request")
		return
	}
	if len(req.Content) > 2048 {
		h.Logger.Warn("content too long",
			"installHash", installHash[:8],
			"length", len(req.Content))
		writeError(w, http.StatusBadRequest, "bad_request")
		return
	}
	if req.Sender == "" {
		h.Logger.Warn("empty sender",
			"installHash", installHash[:8])
		writeError(w, http.StatusBadRequest, "bad_request")
		return
	}
	if len(req.Sender) > 64 {
		h.Logger.Warn("sender too long",
			"installHash", installHash[:8],
			"length", len(req.Sender))
		writeError(w, http.StatusBadRequest, "bad_request")
		return
	}
	if !inputCurrencyPattern.MatchString(req.Currency) {
		h.Logger.Warn("invalid currency",
			"installHash", installHash[:8])
		writeError(w, http.StatusBadRequest, "bad_request")
		return
	}

	// 3. Enforce quota. Quota is charged before the LLM call, and tokens are
	// attributed to the admitted day, not the day the call finishes. A call
	// admitted at 23:59:59 that finishes after midnight is charged to the day
	// it was admitted.
	decision := h.Limiter.Admit(installHash)
	if !decision.Allowed {
		if decision.Reason == quota.ReasonGlobal {
			h.Logger.Warn("global capacity reached",
				"installHash", installHash[:8])
			writeError(w, http.StatusServiceUnavailable, "capacity")
			return
		}
		h.Logger.Warn("rate limited",
			"installHash", installHash[:8],
			"reason", decision.Reason,
			"retryAfter", decision.RetryAfter)
		writeRateLimited(w, decision.RetryAfter, 0)
		return
	}

	// 4. Call the classifier.
	llmReq := llm.Request{
		Sender:   req.Sender,
		Content:  req.Content,
		Currency: req.Currency,
	}
	resp, err := h.Classifier.Classify(ctx, llmReq)
	if err != nil {
		// Map a *llm.CallError via errors.As: status 429 → rate_limited;
		// otherwise retryable → 503 upstream; otherwise → 400 upstream_rejected.
		// A non-*llm.CallError is 503 upstream.
		var callErr *llm.CallError
		if errors.As(err, &callErr) {
			if callErr.Status == 429 {
				h.Logger.Warn("upstream rate limited",
					"installHash", installHash[:8],
					"status", callErr.Status,
					"retryAfter", callErr.RetryAfter,
					"resetAtEpochMs", callErr.ResetAtEpochMs)
				writeRateLimited(w, callErr.RetryAfter, callErr.ResetAtEpochMs)
				return
			}
			if callErr.Retryable {
				h.Logger.Warn("upstream retryable error",
					"installHash", installHash[:8],
					"status", callErr.Status,
					"error", callErr.Message)
				writeError(w, http.StatusServiceUnavailable, "upstream")
				return
			}
			h.Logger.Warn("upstream rejected request",
				"installHash", installHash[:8],
				"status", callErr.Status,
				"error", callErr.Message)
			writeError(w, http.StatusBadRequest, "upstream_rejected")
			return
		}
		h.Logger.Error("classifier failed",
			"installHash", installHash[:8],
			"error", err)
		writeError(w, http.StatusServiceUnavailable, "upstream")
		return
	}

	// 5. Record tokens against the admitted day.
	h.Limiter.RecordTokens(installHash, decision.Day, resp.TotalTokens)

	latency := h.Now().Sub(start)
	h.Logger.Info("classify success",
		"installHash", installHash[:8],
		"latency", latency,
		"tokens", resp.TotalTokens)

	writeJSON(w, http.StatusOK, resp.Result)
}
