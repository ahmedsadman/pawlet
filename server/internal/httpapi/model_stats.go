package httpapi

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net/http"
	"strings"
	"time"

	"github.com/ahmedsadman/pawlet/server/internal/metrics"
	"github.com/ahmedsadman/pawlet/server/internal/store"
	"github.com/ahmedsadman/pawlet/server/internal/token"
)

// Limits on a /v1/model-stats body. The app sends at most the last 30 UTC
// days, one row per (day, app version).
const (
	modelStatsMaxBody    = 4 << 10
	modelStatsMaxDays    = 31
	modelStatsPastDays   = 30
	modelStatsFutureDays = 1 // a phone clock slightly ahead of UTC midnight
	modelStatsMaxCount   = 100_000
)

// ModelStatsHandler stores each install's daily on-device model verdict counts.
type ModelStatsHandler struct {
	Issuer  *token.Issuer
	Store   *store.Store
	Limiter *RollingLimiter
	Now     func() time.Time
	Logger  *slog.Logger
	Metrics Counter // nil-safe: tests may construct without one
}

type modelStatsRequest struct {
	Days []modelStatsEntry `json:"days"`
}

type modelStatsEntry struct {
	Day            string `json:"day"`
	AppVersionCode int64  `json:"appVersionCode"`
	Accepted       int64  `json:"accepted"`
	Declined       int64  `json:"declined"`
	Unavailable    int64  `json:"unavailable"`
}

// validateModelStats checks a decoded body against the limits above and
// returns it as store rows. today is the server's current time; only its UTC
// day matters.
func validateModelStats(req modelStatsRequest, today time.Time) ([]store.ModelStatsDay, error) {
	if len(req.Days) == 0 || len(req.Days) > modelStatsMaxDays {
		return nil, fmt.Errorf("want 1-%d days, got %d", modelStatsMaxDays, len(req.Days))
	}
	utc := today.UTC()
	earliest := utc.AddDate(0, 0, -modelStatsPastDays).Format(time.DateOnly)
	latest := utc.AddDate(0, 0, modelStatsFutureDays).Format(time.DateOnly)

	type key struct {
		day     string
		version int64
	}
	seen := make(map[key]bool, len(req.Days))
	out := make([]store.ModelStatsDay, 0, len(req.Days))
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
		for _, n := range []int64{e.Accepted, e.Declined, e.Unavailable} {
			if n < 0 || n > modelStatsMaxCount {
				return nil, fmt.Errorf("entry %d: count out of range", i)
			}
		}
		k := key{e.Day, e.AppVersionCode}
		if seen[k] {
			return nil, fmt.Errorf("entry %d: duplicate day and appVersionCode", i)
		}
		seen[k] = true
		out = append(out, store.ModelStatsDay{
			Day:            e.Day,
			AppVersionCode: e.AppVersionCode,
			Accepted:       e.Accepted,
			Declined:       e.Declined,
			Unavailable:    e.Unavailable,
		})
	}
	return out, nil
}

// ModelStats stores the caller's per-day verdict counts. Checks run in the
// same order as Classify: token, ban, rate limit, body. Every exit counts one
// model_stats_outcome key. The body holds counts only, never message content.
func (h *ModelStatsHandler) ModelStats(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	// 1. Authenticate.
	rawToken, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || rawToken == "" {
		h.Logger.Warn("model stats: missing or malformed authorization header")
		h.fail(w, http.StatusUnauthorized, metrics.Unauthorized, "unauthorized")
		return
	}
	installHash, err := h.Issuer.Verify(rawToken, h.Now())
	if err != nil {
		h.Logger.Warn("model stats: token verification failed", "error", err)
		h.fail(w, http.StatusUnauthorized, metrics.Unauthorized, "unauthorized")
		return
	}
	// A SHA-256 hex subject is always 64 chars; anything shorter was signed
	// with our key but not minted by us.
	if len(installHash) < 8 {
		h.Logger.Warn("model stats: token subject is not an install hash")
		h.fail(w, http.StatusUnauthorized, metrics.Unauthorized, "unauthorized")
		return
	}

	// 2. Ban check. A token for an install we never recorded is stale: make
	// the client re-attest.
	install, err := h.Store.Install(ctx, installHash)
	if errors.Is(err, store.ErrNotFound) {
		h.Logger.Warn("model stats: token for unknown install", "installHash", shortHash(installHash))
		h.fail(w, http.StatusUnauthorized, metrics.Unauthorized, "unauthorized")
		return
	}
	if err != nil {
		h.Logger.Error("model stats: failed to read install",
			"installHash", shortHash(installHash), "error", err)
		h.fail(w, http.StatusInternalServerError, metrics.Internal, "internal")
		return
	}
	if install.Banned {
		h.Logger.Warn("model stats: banned install", "installHash", shortHash(installHash))
		h.fail(w, http.StatusForbidden, metrics.Banned, "banned")
		return
	}

	// 3. Per-install rate limit.
	if allowed, retryAfter := h.Limiter.Allow(installHash); !allowed {
		h.Logger.Warn("model stats: rate limited", "installHash", shortHash(installHash))
		count(h.Metrics, metrics.ModelStatsOutcome, metrics.RateLimited)
		writeRateLimited(w, retryAfter, 0)
		return
	}

	// 4. Strict decode: bounded size, no unknown fields, exactly one value.
	r.Body = http.MaxBytesReader(w, r.Body, modelStatsMaxBody)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	var req modelStatsRequest
	if err := dec.Decode(&req); err != nil {
		h.Logger.Warn("model stats: malformed body", "installHash", shortHash(installHash), "error", err)
		h.fail(w, http.StatusBadRequest, metrics.BadRequest, "bad_request")
		return
	}
	if err := dec.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		h.Logger.Warn("model stats: trailing data after body", "installHash", shortHash(installHash))
		h.fail(w, http.StatusBadRequest, metrics.BadRequest, "bad_request")
		return
	}

	// 5. Validate.
	days, err := validateModelStats(req, h.Now())
	if err != nil {
		h.Logger.Warn("model stats: invalid body", "installHash", shortHash(installHash), "error", err)
		h.fail(w, http.StatusBadRequest, metrics.BadRequest, "bad_request")
		return
	}

	// 6. Replace the stored rows in one transaction.
	if err := h.Store.ReplaceModelStats(ctx, installHash, days); err != nil {
		h.Logger.Error("model stats: failed to store",
			"installHash", shortHash(installHash), "error", err)
		h.fail(w, http.StatusInternalServerError, metrics.Internal, "internal")
		return
	}

	// 7. Done.
	h.Logger.Info("model stats stored", "installHash", shortHash(installHash), "days", len(days))
	count(h.Metrics, metrics.ModelStatsOutcome, metrics.OK)
	w.WriteHeader(http.StatusNoContent)
}

// fail counts the outcome and writes the error body.
func (h *ModelStatsHandler) fail(w http.ResponseWriter, status int, outcome, code string) {
	count(h.Metrics, metrics.ModelStatsOutcome, outcome)
	writeError(w, status, code)
}
