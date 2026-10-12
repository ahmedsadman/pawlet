package httpapi

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net"
	"net/http"
	"time"

	"github.com/ahmedsadman/pawlet/server/internal/attest"
	"github.com/ahmedsadman/pawlet/server/internal/clientip"
	"github.com/ahmedsadman/pawlet/server/internal/metrics"
	"github.com/ahmedsadman/pawlet/server/internal/store"
)

// Limits on a /v1/heartbeat body. The app keeps today and the 29 days before.
const (
	heartbeatMaxBody    = 4 << 10
	heartbeatMaxDays    = 31
	heartbeatPastDays   = 30
	heartbeatFutureDays = 1 // a phone clock slightly ahead of UTC midnight
)

// HeartbeatHandler records which days an install was opened or ran.
//
// Unauthenticated by design: install analytics must not depend on proxy
// sessions, and bring-your-own-key installs never attest. The install ID is
// hashed exactly as /v1/session hashes it, and an install first seen here is
// stored unattested so the dashboard can tell it apart. Banned installs are
// still recorded: a ban only refuses the LLM.
type HeartbeatHandler struct {
	Store        *store.Store
	Limiter      *hourlyLimiter // nil-safe: tests may construct without one
	TrustedProxy *net.IPNet
	Now          func() time.Time
	Logger       *slog.Logger
	Metrics      Counter // nil-safe: tests may construct without one
}

type heartbeatRequest struct {
	InstallID string           `json:"installId"`
	Days      []heartbeatEntry `json:"days"`
}

type heartbeatEntry struct {
	Day            string `json:"day"`
	AppVersionCode int64  `json:"appVersionCode"`
	Opened         bool   `json:"opened"`
	Alive          bool   `json:"alive"`
}

// validInstallID matches what the app generates: 256 random bits as 64
// lowercase hex characters.
func validInstallID(id string) bool {
	if len(id) != 64 {
		return false
	}
	for _, c := range id {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

// validateHeartbeat checks a decoded body and returns its days as store rows.
// today is the server's current time; only its UTC day matters.
func validateHeartbeat(req heartbeatRequest, today time.Time) ([]store.HeartbeatDay, error) {
	if !validInstallID(req.InstallID) {
		return nil, errors.New("installId is not 64 lowercase hex characters")
	}
	if len(req.Days) == 0 || len(req.Days) > heartbeatMaxDays {
		return nil, fmt.Errorf("want 1-%d days, got %d", heartbeatMaxDays, len(req.Days))
	}
	utc := today.UTC()
	earliest := utc.AddDate(0, 0, -heartbeatPastDays).Format(time.DateOnly)
	latest := utc.AddDate(0, 0, heartbeatFutureDays).Format(time.DateOnly)

	seen := make(map[string]bool, len(req.Days))
	out := make([]store.HeartbeatDay, 0, len(req.Days))
	for i, e := range req.Days {
		parsed, err := time.Parse(time.DateOnly, e.Day)
		if err != nil || parsed.Format(time.DateOnly) != e.Day {
			return nil, fmt.Errorf("entry %d: day is not YYYY-MM-DD", i)
		}
		// YYYY-MM-DD strings sort in date order, so string bounds suffice.
		if e.Day < earliest || e.Day > latest {
			return nil, fmt.Errorf("entry %d: day %s outside %s..%s", i, e.Day, earliest, latest)
		}
		if e.AppVersionCode < 1 || e.AppVersionCode > math.MaxInt32 {
			return nil, fmt.Errorf("entry %d: appVersionCode out of range", i)
		}
		if !e.Opened && !e.Alive {
			return nil, fmt.Errorf("entry %d: neither opened nor alive", i)
		}
		if seen[e.Day] {
			return nil, fmt.Errorf("entry %d: duplicate day", i)
		}
		seen[e.Day] = true
		out = append(out, store.HeartbeatDay{
			Day: e.Day, AppVersionCode: e.AppVersionCode, Opened: e.Opened, Alive: e.Alive,
		})
	}
	return out, nil
}

// Heartbeat stores the caller's reported days. Every exit counts one
// heartbeat_outcome key. The body holds dates, a version and two flags only.
func (h *HeartbeatHandler) Heartbeat(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	// 1. Per-IP rate limit. Generous: carrier NAT puts many phones behind one
	// address, and each sends at most about one batch an hour.
	if h.Limiter != nil {
		ip := clientip.From(r, h.TrustedProxy)
		if !h.Limiter.allow(ip) {
			h.Logger.Warn("heartbeat: rate limited", "ip", ip)
			count(h.Metrics, metrics.HeartbeatOutcome, metrics.RateLimited)
			writeRateLimited(w, time.Hour, 0)
			return
		}
	}

	// 2. Strict decode: bounded size, no unknown fields, exactly one value.
	r.Body = http.MaxBytesReader(w, r.Body, heartbeatMaxBody)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	var req heartbeatRequest
	if err := dec.Decode(&req); err != nil {
		h.Logger.Warn("heartbeat: malformed body", "error", err)
		h.fail(w, http.StatusBadRequest, metrics.BadRequest, "bad_request")
		return
	}
	if err := dec.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		h.Logger.Warn("heartbeat: trailing data after body")
		h.fail(w, http.StatusBadRequest, metrics.BadRequest, "bad_request")
		return
	}

	// 3. Validate.
	days, err := validateHeartbeat(req, h.Now())
	if err != nil {
		h.Logger.Warn("heartbeat: invalid body", "error", err)
		h.fail(w, http.StatusBadRequest, metrics.BadRequest, "bad_request")
		return
	}

	// 4. Store under the hash, never the ID itself.
	installHash := attest.InstallHash(req.InstallID)
	if err := h.Store.RecordHeartbeat(ctx, installHash, h.Now(), days); err != nil {
		h.Logger.Error("heartbeat: failed to store", "installHash", shortHash(installHash), "error", err)
		h.fail(w, http.StatusServiceUnavailable, metrics.Internal, "internal")
		return
	}

	count(h.Metrics, metrics.HeartbeatOutcome, metrics.OK)
	w.WriteHeader(http.StatusNoContent)
}

// fail counts the outcome and writes the error body.
func (h *HeartbeatHandler) fail(w http.ResponseWriter, status int, outcome, code string) {
	count(h.Metrics, metrics.HeartbeatOutcome, outcome)
	writeError(w, status, code)
}
