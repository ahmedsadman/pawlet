package httpapi

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/ahmedsadman/pawlet/server/internal/attest"
	"github.com/ahmedsadman/pawlet/server/internal/metrics"
	"github.com/ahmedsadman/pawlet/server/internal/store"
)

var (
	heartbeatID        = strings.Repeat("ab", 32)
	validHeartbeatBody = `{"installId":"` + heartbeatID +
		`","days":[{"day":"2026-10-09","appVersionCode":28,"opened":true,"alive":true}]}`
)

type heartbeatHarness struct {
	handler *HeartbeatHandler
	store   *store.Store
	counter *fakeCounter
}

func newHeartbeatHarness(t *testing.T, perHour int) *heartbeatHarness {
	t.Helper()
	st, err := store.Open(t.TempDir() + "/test.db")
	if err != nil {
		t.Fatalf("store.Open() failed: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	clock := &fakeClock{current: time.Date(2026, 10, 10, 12, 0, 0, 0, time.UTC)}
	counter := newFakeCounter()
	return &heartbeatHarness{
		handler: &HeartbeatHandler{
			Store:   st,
			Limiter: newHourlyLimiter(perHour, clock.now),
			Now:     clock.now,
			Logger:  discardLogger(),
			Metrics: counter,
		},
		store:   st,
		counter: counter,
	}
}

func (h *heartbeatHarness) post(body string) *httptest.ResponseRecorder {
	return h.postFrom(body, "203.0.113.7:5000")
}

func (h *heartbeatHarness) postFrom(body, remoteAddr string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, "/v1/heartbeat", strings.NewReader(body))
	req.RemoteAddr = remoteAddr
	rec := httptest.NewRecorder()
	h.handler.Heartbeat(rec, req)
	return rec
}

func (h *heartbeatHarness) assertOutcome(t *testing.T, rec *httptest.ResponseRecorder, status int, outcome string) {
	t.Helper()
	if rec.Code != status {
		t.Fatalf("status = %d, want %d; body: %s", rec.Code, status, rec.Body.String())
	}
	if got := h.counter.n(metrics.HeartbeatOutcome, outcome); got != 1 {
		t.Errorf("%s/%s counted %d times, want 1", metrics.HeartbeatOutcome, outcome, got)
	}
	if got := h.counter.total(metrics.HeartbeatOutcome); got != 1 {
		t.Errorf("heartbeat_outcome total = %d, want 1", got)
	}
}

func TestHeartbeatStoresAndReturns204(t *testing.T) {
	h := newHeartbeatHarness(t, 10)
	rec := h.post(validHeartbeatBody)
	h.assertOutcome(t, rec, http.StatusNoContent, metrics.OK)

	days, err := h.store.InstallDays(context.Background(), attest.InstallHash(heartbeatID))
	if err != nil {
		t.Fatalf("InstallDays() error = %v", err)
	}
	if len(days) != 1 || days[0].Day != "2026-10-09" || !days[0].Opened || !days[0].Alive || days[0].AppVersionCode != 28 {
		t.Fatalf("days = %+v", days)
	}
}

func TestHeartbeatAcceptsBannedInstalls(t *testing.T) {
	h := newHeartbeatHarness(t, 10)
	hash := attest.InstallHash(heartbeatID)
	if err := h.store.TouchInstall(context.Background(), hash, time.Now(), store.InstallMeta{}); err != nil {
		t.Fatalf("TouchInstall() error = %v", err)
	}
	if err := h.store.Ban(context.Background(), hash, "abuse"); err != nil {
		t.Fatalf("Ban() error = %v", err)
	}
	h.assertOutcome(t, h.post(validHeartbeatBody), http.StatusNoContent, metrics.OK)
}

func TestHeartbeatRateLimitsPerIP(t *testing.T) {
	h := newHeartbeatHarness(t, 1)
	if rec := h.post(validHeartbeatBody); rec.Code != http.StatusNoContent {
		t.Fatalf("first status = %d", rec.Code)
	}
	rec := h.post(validHeartbeatBody)
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429", rec.Code)
	}
	if rec.Header().Get("Retry-After") == "" {
		t.Error("missing Retry-After")
	}
	if got := h.counter.n(metrics.HeartbeatOutcome, metrics.RateLimited); got != 1 {
		t.Errorf("rate_limited counted %d times, want 1", got)
	}
}

func TestHeartbeatIPv6RateLimitsPer64(t *testing.T) {
	h := newHeartbeatHarness(t, 1)
	// Two addresses in the same /64 share a bucket.
	if rec := h.postFrom(validHeartbeatBody, "[2001:db8::1]:5000"); rec.Code != http.StatusNoContent {
		t.Fatalf("first status = %d", rec.Code)
	}
	rec := h.postFrom(validHeartbeatBody, "[2001:db8::2]:5000")
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("second IPv6 in same /64 status = %d, want 429", rec.Code)
	}
}

func TestHeartbeatIPv4RateLimitsPerAddress(t *testing.T) {
	h := newHeartbeatHarness(t, 1)
	// Different IPv4 addresses have separate buckets.
	if rec := h.postFrom(validHeartbeatBody, "203.0.113.7:5000"); rec.Code != http.StatusNoContent {
		t.Fatalf("first status = %d", rec.Code)
	}
	rec := h.postFrom(validHeartbeatBody, "203.0.113.8:5000")
	if rec.Code != http.StatusNoContent {
		t.Fatalf("different IPv4 status = %d, want 204", rec.Code)
	}
}

func TestHeartbeatRejectsBadBodies(t *testing.T) {
	cases := map[string]string{
		"not json":      `nope`,
		"unknown field": `{"installId":"` + heartbeatID + `","days":[{"day":"2026-10-09","appVersionCode":28,"opened":true,"alive":true}],"extra":1}`,
		"trailing data": validHeartbeatBody + `{}`,
		"invalid":       `{"installId":"short","days":[{"day":"2026-10-09","appVersionCode":28,"opened":true,"alive":true}]}`,
		"oversize body": `{"installId":"` + heartbeatID + `","days":[{"day":"2026-10-09","appVersionCode":28,"opened":true,"alive":true,"padding":"` + strings.Repeat("x", 4096) + `"}]}`,
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			h := newHeartbeatHarness(t, 10)
			h.assertOutcome(t, h.post(body), http.StatusBadRequest, metrics.BadRequest)
		})
	}
}

func TestHeartbeatStoreError(t *testing.T) {
	h := newHeartbeatHarness(t, 10)
	_ = h.store.Close()
	rec := h.post(validHeartbeatBody)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", rec.Code)
	}
	if got := h.counter.n(metrics.HeartbeatOutcome, metrics.Internal); got != 1 {
		t.Errorf("internal counted %d times, want 1", got)
	}
}

// heartbeatToday is 2026-10-10 UTC, so the accepted window is 2026-09-10..2026-10-11.
var heartbeatToday = time.Date(2026, 10, 10, 23, 30, 0, 0, time.UTC)

func hbEntry(day string) heartbeatEntry {
	return heartbeatEntry{Day: day, AppVersionCode: 28, Alive: true}
}

func TestValidateHeartbeat(t *testing.T) {
	good := heartbeatRequest{InstallID: heartbeatID, Days: []heartbeatEntry{
		hbEntry("2026-09-10"), {Day: "2026-10-11", AppVersionCode: 2147483647, Opened: true},
	}}
	got, err := validateHeartbeat(good, heartbeatToday)
	if err != nil {
		t.Fatalf("validateHeartbeat(good) error = %v", err)
	}
	want := []store.HeartbeatDay{
		{Day: "2026-09-10", AppVersionCode: 28, Alive: true},
		{Day: "2026-10-11", AppVersionCode: 2147483647, Opened: true},
	}
	if len(got) != 2 || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("days = %+v, want %+v", got, want)
	}

	tooMany := make([]heartbeatEntry, 32)
	for i := range tooMany {
		tooMany[i] = hbEntry(time.Date(2026, 9, 10+i, 0, 0, 0, 0, time.UTC).Format(time.DateOnly))
	}
	bad := map[string]heartbeatRequest{
		"empty install id": {InstallID: "", Days: []heartbeatEntry{hbEntry("2026-10-10")}},
		"uppercase id":     {InstallID: strings.ToUpper(heartbeatID), Days: []heartbeatEntry{hbEntry("2026-10-10")}},
		"short id":         {InstallID: heartbeatID[:63], Days: []heartbeatEntry{hbEntry("2026-10-10")}},
		"no days":          {InstallID: heartbeatID},
		"too many days":    {InstallID: heartbeatID, Days: tooMany},
		"bad day format":   {InstallID: heartbeatID, Days: []heartbeatEntry{hbEntry("2026-10-1")}},
		"day too old":      {InstallID: heartbeatID, Days: []heartbeatEntry{hbEntry("2026-09-09")}},
		"day too new":      {InstallID: heartbeatID, Days: []heartbeatEntry{hbEntry("2026-10-12")}},
		"zero version":     {InstallID: heartbeatID, Days: []heartbeatEntry{{Day: "2026-10-10", Alive: true}}},
		"version too big":  {InstallID: heartbeatID, Days: []heartbeatEntry{{Day: "2026-10-10", AppVersionCode: 2147483648, Alive: true}}},
		"no signal":        {InstallID: heartbeatID, Days: []heartbeatEntry{{Day: "2026-10-10", AppVersionCode: 28}}},
		"duplicate day":    {InstallID: heartbeatID, Days: []heartbeatEntry{hbEntry("2026-10-10"), hbEntry("2026-10-10")}},
	}
	for name, req := range bad {
		t.Run(name, func(t *testing.T) {
			if _, err := validateHeartbeat(req, heartbeatToday); err == nil {
				t.Errorf("validateHeartbeat() error = nil, want an error")
			}
		})
	}
}

func TestHeartbeatLimitKey(t *testing.T) {
	cases := []struct {
		name string
		ip   string
		want string
	}{
		{"IPv4", "203.0.113.7", "203.0.113.7"},
		{"IPv6 same /64", "2001:db8::1", "2001:db8::/64"},
		{"IPv6 same /64 different host", "2001:db8::2", "2001:db8::/64"},
		{"IPv6 different /64", "2001:db8:1::1", "2001:db8:1::/64"},
		{"unparseable", "invalid", "invalid"},
		{"empty", "", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := heartbeatLimitKey(tc.ip)
			if got != tc.want {
				t.Errorf("heartbeatLimitKey(%q) = %q, want %q", tc.ip, got, tc.want)
			}
		})
	}
}

func TestHeartbeatAcceptsLLMGroup(t *testing.T) {
	h := newHeartbeatHarness(t, 10)
	body := `{"installId":"` + heartbeatID +
		`","days":[{"day":"2026-10-09","appVersionCode":28,"opened":true,"alive":true,"llm":"off"}]}`
	rec := h.post(body)
	h.assertOutcome(t, rec, http.StatusNoContent, metrics.OK)

	days, err := h.store.InstallDays(context.Background(), attest.InstallHash(heartbeatID))
	if err != nil {
		t.Fatalf("InstallDays() error = %v", err)
	}
	if len(days) != 1 || days[0].LLM != "off" {
		t.Fatalf("days = %+v, want LLM = off", days)
	}
}

func TestHeartbeatRejectsUnknownLLMGroup(t *testing.T) {
	h := newHeartbeatHarness(t, 10)
	body := `{"installId":"` + heartbeatID +
		`","days":[{"day":"2026-10-09","appVersionCode":28,"opened":true,"alive":true,"llm":"maybe"}]}`
	h.assertOutcome(t, h.post(body), http.StatusBadRequest, metrics.BadRequest)
}

func TestHeartbeatWithoutLLMStillAccepted(t *testing.T) {
	h := newHeartbeatHarness(t, 10)
	rec := h.post(validHeartbeatBody)
	h.assertOutcome(t, rec, http.StatusNoContent, metrics.OK)

	days, err := h.store.InstallDays(context.Background(), attest.InstallHash(heartbeatID))
	if err != nil {
		t.Fatalf("InstallDays() error = %v", err)
	}
	if len(days) != 1 || days[0].LLM != "" {
		t.Fatalf("days = %+v, want LLM = empty", days)
	}
}
