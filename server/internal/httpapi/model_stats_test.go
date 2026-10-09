package httpapi

import (
	"context"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/ahmedsadman/pawlet/server/internal/metrics"
	"github.com/ahmedsadman/pawlet/server/internal/store"
	"github.com/ahmedsadman/pawlet/server/internal/token"
)

var statsHash = strings.Repeat("s", 64)

const validStatsBody = `{"days":[{"day":"2026-10-09","appVersionCode":21,"accepted":40,"declined":9,"unavailable":0}]}`

type statsHarness struct {
	handler *ModelStatsHandler
	store   *store.Store
	issuer  *token.Issuer
	clock   *fakeClock
	counter *fakeCounter
}

func newStatsHarness(t *testing.T) *statsHarness {
	t.Helper()
	st, err := store.Open(t.TempDir() + "/test.db")
	if err != nil {
		t.Fatalf("store.Open() failed: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })

	clock := &fakeClock{current: time.Date(2026, 10, 10, 12, 0, 0, 0, time.UTC)}
	issuer := token.New([]byte("test-secret"), 24*time.Hour)
	counter := newFakeCounter()
	return &statsHarness{
		handler: &ModelStatsHandler{
			Issuer:  issuer,
			Store:   st,
			Limiter: NewModelStatsLimiter(clock.now),
			Now:     clock.now,
			Logger:  discardLogger(),
			Metrics: counter,
		},
		store:   st,
		issuer:  issuer,
		clock:   clock,
		counter: counter,
	}
}

func (h *statsHarness) touch(t *testing.T, hash string) {
	t.Helper()
	if err := h.store.TouchInstall(context.Background(), hash, h.clock.now(), store.InstallMeta{}); err != nil {
		t.Fatalf("TouchInstall() error = %v", err)
	}
}

// post sends body for hash with a freshly minted token.
func (h *statsHarness) post(t *testing.T, hash, body string) *httptest.ResponseRecorder {
	t.Helper()
	tok, err := h.issuer.Mint(hash, h.clock.now())
	if err != nil {
		t.Fatalf("Mint() error = %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/model-stats", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+tok)
	rec := httptest.NewRecorder()
	h.handler.ModelStats(rec, req)
	return rec
}

// assertError checks status, error code and that exactly one outcome key was
// counted.
func (h *statsHarness) assertError(t *testing.T, rec *httptest.ResponseRecorder, status int, code, outcome string) {
	t.Helper()
	if rec.Code != status {
		t.Fatalf("status = %d, want %d; body: %s", rec.Code, status, rec.Body.String())
	}
	if want := `{"error":"` + code + `"}`; strings.TrimSpace(rec.Body.String()) != want {
		t.Errorf("body = %s, want %s", rec.Body.String(), want)
	}
	if got := h.counter.n(metrics.ModelStatsOutcome, outcome); got != 1 {
		t.Errorf("%s/%s counted %d times, want 1", metrics.ModelStatsOutcome, outcome, got)
	}
	if got := h.counter.total(metrics.ModelStatsOutcome); got != 1 {
		t.Errorf("model_stats_outcome total = %d, want 1", got)
	}
}

func TestModelStatsStoresAndReturns204(t *testing.T) {
	h := newStatsHarness(t)
	h.touch(t, statsHash)

	rec := h.post(t, statsHash, validStatsBody)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204; body: %s", rec.Code, rec.Body.String())
	}
	if rec.Body.Len() != 0 {
		t.Errorf("body = %q, want empty", rec.Body.String())
	}
	got, err := h.store.ModelStatsForInstall(context.Background(), statsHash)
	if err != nil {
		t.Fatalf("ModelStatsForInstall() error = %v", err)
	}
	want := []store.ModelStatsDay{{Day: "2026-10-09", AppVersionCode: 21, Accepted: 40, Declined: 9}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("stored = %+v, want %+v", got, want)
	}
	if n := h.counter.n(metrics.ModelStatsOutcome, metrics.OK); n != 1 {
		t.Errorf("ok counted %d times, want 1", n)
	}
}

func TestModelStatsResendReplaces(t *testing.T) {
	h := newStatsHarness(t)
	h.touch(t, statsHash)

	h.post(t, statsHash, validStatsBody)
	rec := h.post(t, statsHash,
		`{"days":[{"day":"2026-10-09","appVersionCode":21,"accepted":42,"declined":9,"unavailable":1}]}`)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204", rec.Code)
	}

	got, err := h.store.ModelStatsForInstall(context.Background(), statsHash)
	if err != nil {
		t.Fatalf("ModelStatsForInstall() error = %v", err)
	}
	want := []store.ModelStatsDay{{Day: "2026-10-09", AppVersionCode: 21, Accepted: 42, Declined: 9, Unavailable: 1}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("stored = %+v, want %+v (replaced, not added)", got, want)
	}
}

func TestModelStatsRejectsBadAuth(t *testing.T) {
	cases := []struct {
		name   string
		header string
	}{
		{"missing header", ""},
		{"not bearer", "Basic abc"},
		{"empty bearer", "Bearer "},
		{"garbage token", "Bearer not-a-jwt"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h := newStatsHarness(t)
			req := httptest.NewRequest(http.MethodPost, "/v1/model-stats", strings.NewReader(validStatsBody))
			if c.header != "" {
				req.Header.Set("Authorization", c.header)
			}
			rec := httptest.NewRecorder()
			h.handler.ModelStats(rec, req)
			h.assertError(t, rec, http.StatusUnauthorized, "unauthorized", metrics.Unauthorized)
		})
	}
}

func TestModelStatsRejectsExpiredToken(t *testing.T) {
	h := newStatsHarness(t)
	h.touch(t, statsHash)
	tok, err := h.issuer.Mint(statsHash, h.clock.now())
	if err != nil {
		t.Fatalf("Mint() error = %v", err)
	}
	h.clock.current = h.clock.current.Add(25 * time.Hour)

	req := httptest.NewRequest(http.MethodPost, "/v1/model-stats", strings.NewReader(validStatsBody))
	req.Header.Set("Authorization", "Bearer "+tok)
	rec := httptest.NewRecorder()
	h.handler.ModelStats(rec, req)

	h.assertError(t, rec, http.StatusUnauthorized, "unauthorized", metrics.Unauthorized)
}

func TestModelStatsRejectsShortSubject(t *testing.T) {
	h := newStatsHarness(t)

	rec := h.post(t, "abc", validStatsBody)

	h.assertError(t, rec, http.StatusUnauthorized, "unauthorized", metrics.Unauthorized)
}

func TestModelStatsRejectsUnknownInstall(t *testing.T) {
	h := newStatsHarness(t)

	rec := h.post(t, statsHash, validStatsBody)

	h.assertError(t, rec, http.StatusUnauthorized, "unauthorized", metrics.Unauthorized)
}

func TestModelStatsRejectsBannedInstall(t *testing.T) {
	h := newStatsHarness(t)
	h.touch(t, statsHash)
	if err := h.store.Ban(context.Background(), statsHash, "test"); err != nil {
		t.Fatalf("Ban() error = %v", err)
	}

	rec := h.post(t, statsHash, validStatsBody)

	h.assertError(t, rec, http.StatusForbidden, "banned", metrics.Banned)
	if got, _ := h.store.ModelStatsForInstall(context.Background(), statsHash); len(got) != 0 {
		t.Errorf("banned install stored %+v, want nothing", got)
	}
}

func TestModelStatsRateLimitsPerInstall(t *testing.T) {
	h := newStatsHarness(t)
	h.touch(t, statsHash)
	other := strings.Repeat("o", 64)
	h.touch(t, other)

	for i := 0; i < 12; i++ {
		if rec := h.post(t, statsHash, validStatsBody); rec.Code != http.StatusNoContent {
			t.Fatalf("request %d status = %d, want 204", i+1, rec.Code)
		}
	}
	h.counter = newFakeCounter()
	h.handler.Metrics = h.counter

	rec := h.post(t, statsHash, validStatsBody)
	h.assertError(t, rec, http.StatusTooManyRequests, "rate_limited", metrics.RateLimited)
	if got := rec.Header().Get("Retry-After"); got != "3600" {
		t.Errorf("Retry-After = %q, want 3600", got)
	}

	if rec := h.post(t, other, validStatsBody); rec.Code != http.StatusNoContent {
		t.Errorf("other install status = %d, want 204 (limit is per install)", rec.Code)
	}
}

func TestModelStatsRejectsBadBodies(t *testing.T) {
	cases := []struct {
		name string
		body string
	}{
		{"not json", `days`},
		{"unknown top-level field", `{"days":[],"extra":1}`},
		{"unknown entry field", `{"days":[{"day":"2026-10-09","appVersionCode":21,"llm":3}]}`},
		{"fractional count", `{"days":[{"day":"2026-10-09","appVersionCode":21,"accepted":1.5}]}`},
		{"trailing value", validStatsBody + `{}`},
		{"over 4 KB", `{"days":[{"day":"2026-10-09","appVersionCode":21}]` + strings.Repeat(" ", 4<<10) + `}`},
		{"empty days", `{"days":[]}`},
		{"day out of window", `{"days":[{"day":"2026-09-09","appVersionCode":21}]}`},
		{"duplicate pair", `{"days":[{"day":"2026-10-09","appVersionCode":21},{"day":"2026-10-09","appVersionCode":21}]}`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h := newStatsHarness(t)
			h.touch(t, statsHash)

			rec := h.post(t, statsHash, c.body)

			h.assertError(t, rec, http.StatusBadRequest, "bad_request", metrics.BadRequest)
			if got, _ := h.store.ModelStatsForInstall(context.Background(), statsHash); len(got) != 0 {
				t.Errorf("rejected body stored %+v, want nothing", got)
			}
		})
	}
}

func TestModelStatsStoreFailureIsInternal(t *testing.T) {
	h := newStatsHarness(t)
	h.touch(t, statsHash)
	tok, err := h.issuer.Mint(statsHash, h.clock.now())
	if err != nil {
		t.Fatalf("Mint() error = %v", err)
	}
	_ = h.store.Close()

	req := httptest.NewRequest(http.MethodPost, "/v1/model-stats", strings.NewReader(validStatsBody))
	req.Header.Set("Authorization", "Bearer "+tok)
	rec := httptest.NewRecorder()
	h.handler.ModelStats(rec, req)

	h.assertError(t, rec, http.StatusInternalServerError, "internal", metrics.Internal)
}
