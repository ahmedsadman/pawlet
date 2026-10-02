package httpapi

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"time"

	"github.com/ahmedsadman/pawlet/server/internal/attest"
	"github.com/ahmedsadman/pawlet/server/internal/store"
	"github.com/ahmedsadman/pawlet/server/internal/token"
)

// SessionHandler issues challenges and exchanges attested integrity tokens for
// session JWTs.
type SessionHandler struct {
	Challenges       *attest.Challenges
	Decoder          attest.Decoder
	Issuer           *token.Issuer
	Store            *store.Store
	Policy           attest.Policy
	Now              func() time.Time
	Logger           *slog.Logger
	ChallengeLimiter *hourlyLimiter // nil-safe: existing tests construct without one
	TrustedProxy     *net.IPNet
}

type challengeResponse struct {
	Challenge string `json:"challenge"`
}

type sessionRequest struct {
	InstallID      string `json:"installId"`
	Challenge      string `json:"challenge"`
	IntegrityToken string `json:"integrityToken"`
}

type sessionResponse struct {
	Token     string `json:"token"`
	ExpiresAt int64  `json:"expiresAt"`
}

// Challenge issues a single-use nonce for the client to bind into its integrity
// token.
func (h *SessionHandler) Challenge(w http.ResponseWriter, r *http.Request) {
	// Rate limit by client IP to prevent unbounded challenge allocation.
	if h.ChallengeLimiter != nil {
		ip := clientIP(r, h.TrustedProxy)
		if !h.ChallengeLimiter.allow(ip) {
			h.Logger.Warn("challenge rate limit exceeded", "ip", ip)
			writeRateLimited(w, time.Hour, 0)
			return
		}
	}

	challenge, err := h.Challenges.Issue()
	if err != nil {
		h.Logger.Error("failed to issue challenge", "error", err)
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	writeJSON(w, http.StatusOK, challengeResponse{Challenge: challenge})
}

// Session verifies an integrity token and mints a 24h session JWT.
func (h *SessionHandler) Session(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	// Bound body to protect against memory exhaustion.
	r.Body = http.MaxBytesReader(w, r.Body, 16<<10)

	var req sessionRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		h.Logger.Warn("malformed session request", "error", err)
		writeError(w, http.StatusBadRequest, "bad_request")
		return
	}

	// Validate required fields.
	if req.InstallID == "" || req.Challenge == "" || req.IntegrityToken == "" {
		h.Logger.Warn("session request missing required field")
		writeError(w, http.StatusBadRequest, "bad_request")
		return
	}

	// Consume the challenge FIRST, before spending a Google decode call. This
	// ordering protects the quota: a replayed or expired challenge is rejected
	// here, not after burning a billable decode.
	if !h.Challenges.Consume(req.Challenge) {
		h.Logger.Warn("challenge consume failed",
			"installHash", attest.InstallHash(req.InstallID))
		writeError(w, http.StatusForbidden, "attestation_failed")
		return
	}

	// Decode the integrity token through Google.
	payload, err := h.Decoder.Decode(ctx, req.IntegrityToken)
	if err != nil {
		// Both ErrDecodeUnreachable and ErrDecodeRejected map to 503. This is
		// deliberate: if Google is down or our service account is misconfigured,
		// that is the operator's problem, not the client's. Returning 403 would
		// tell the Android app it is permanently ineligible and push it into
		// degraded local-only mode over a transient server fault. Log the
		// underlying sentinel so the cause is visible.
		h.Logger.Error("integrity decode failed",
			"installHash", attest.InstallHash(req.InstallID),
			"error", err)
		writeError(w, http.StatusServiceUnavailable, "attestation_unavailable")
		return
	}

	// Verify the payload against the policy and the recomputed requestHash.
	wantHash := attest.RequestHash(req.InstallID, req.Challenge)
	if err := attest.Verify(payload, wantHash, h.Policy, h.Now()); err != nil {
		h.Logger.Warn("attestation verification failed",
			"installHash", attest.InstallHash(req.InstallID),
			"error", err)
		writeError(w, http.StatusForbidden, "attestation_failed")
		return
	}

	// Check the ban flag. A first-time install returns ErrNotFound, which is not
	// an error — treat not-found as "not banned" and continue.
	installHash := attest.InstallHash(req.InstallID)
	install, err := h.Store.Install(ctx, installHash)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		h.Logger.Error("failed to read install",
			"installHash", installHash,
			"error", err)
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	if install.Banned {
		h.Logger.Warn("banned install attempted session",
			"installHash", installHash,
			"banReason", install.BanReason)
		writeError(w, http.StatusForbidden, "banned")
		return
	}

	// Touch the install record.
	if err := h.Store.TouchInstall(ctx, installHash, h.Now()); err != nil {
		h.Logger.Error("failed to touch install",
			"installHash", installHash,
			"error", err)
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}

	// Mint a session JWT.
	sessionToken, err := h.Issuer.Mint(installHash, h.Now())
	if err != nil {
		h.Logger.Error("failed to mint session token",
			"installHash", installHash,
			"error", err)
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}

	expiresAt := h.Now().Add(h.Issuer.TTL()).Unix()
	writeJSON(w, http.StatusOK, sessionResponse{
		Token:     sessionToken,
		ExpiresAt: expiresAt,
	})
}
