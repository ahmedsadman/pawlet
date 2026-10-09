package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/ahmedsadman/pawlet/server/internal/attest"
	"github.com/ahmedsadman/pawlet/server/internal/metrics"
	"github.com/ahmedsadman/pawlet/server/internal/store"
)

// sessionBody issues a fresh challenge, points the decoder at a genuine
// payload for it (optionally altered by mutate) and returns the request body.
func sessionBody(t *testing.T, h *SessionHandler, d *fakeDecoder, installID string, mutate func(*attest.Payload)) []byte {
	t.Helper()
	challenge, err := h.Challenges.Issue()
	if err != nil {
		t.Fatalf("issue challenge: %v", err)
	}
	p := genuinePayload(installID, challenge, h.Now())
	if mutate != nil {
		mutate(&p)
	}
	d.payload = p
	body, err := json.Marshal(sessionRequest{InstallID: installID, Challenge: challenge, IntegrityToken: "fake-token"})
	if err != nil {
		t.Fatalf("marshal session request: %v", err)
	}
	return body
}

func postSession(h *SessionHandler, body []byte) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	h.Session(rec, httptest.NewRequest(http.MethodPost, "/v1/session", bytes.NewReader(body)))
	return rec
}

func TestSessionRecordsInstallMetaAndDay(t *testing.T) {
	now := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	decoder := &fakeDecoder{}
	h := newTestHandler(t, decoder, now)

	body := sessionBody(t, h, decoder, "install-meta", func(p *attest.Payload) {
		p.AppIntegrity.VersionCode = "18"
		p.DeviceIntegrity.DeviceRecognitionVerdict = []string{"MEETS_DEVICE_INTEGRITY", "MEETS_STRONG_INTEGRITY"}
		p.AccountDetails.AppLicensingVerdict = "LICENSED"
		p.DeviceIntegrity.DeviceAttributes.SdkVersion = 34
	})
	if rec := postSession(h, body); rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body: %s", rec.Code, rec.Body.String())
	}

	hash := attest.InstallHash("install-meta")
	install, err := h.Store.Install(context.Background(), hash)
	if err != nil {
		t.Fatalf("read install: %v", err)
	}
	want := store.InstallMeta{AppVersionCode: 18, DeviceTier: "STRONG", Licensing: "LICENSED", SDKVersion: 34}
	if install.Meta != want {
		t.Fatalf("Meta = %+v, want %+v", install.Meta, want)
	}

	days, err := h.Store.InstallDays(context.Background(), hash)
	if err != nil {
		t.Fatalf("InstallDays() error = %v", err)
	}
	if len(days) != 1 || days[0] != "2026-10-03" {
		t.Fatalf("days = %v, want [2026-10-03]", days)
	}
}

func TestSessionCountsOutcomes(t *testing.T) {
	now := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)

	cases := []struct {
		name string
		run  func(t *testing.T, h *SessionHandler, d *fakeDecoder)
		want string
	}{
		{
			name: "ok",
			run: func(t *testing.T, h *SessionHandler, d *fakeDecoder) {
				postSession(h, sessionBody(t, h, d, "i-ok", nil))
			},
			want: metrics.OK,
		},
		{
			name: "bad request",
			run: func(_ *testing.T, h *SessionHandler, _ *fakeDecoder) {
				postSession(h, []byte(`{"installId": "broken`))
			},
			want: metrics.BadRequest,
		},
		{
			name: "challenge invalid",
			run: func(_ *testing.T, h *SessionHandler, _ *fakeDecoder) {
				body, _ := json.Marshal(sessionRequest{InstallID: "i", Challenge: "never-issued", IntegrityToken: "t"})
				postSession(h, body)
			},
			want: metrics.ChallengeInvalid,
		},
		{
			name: "attest unavailable",
			run: func(t *testing.T, h *SessionHandler, d *fakeDecoder) {
				body := sessionBody(t, h, d, "i-down", nil)
				d.shouldError = true
				d.err = attest.ErrDecodeUnreachable
				postSession(h, body)
			},
			want: metrics.AttestUnavailable,
		},
		{
			name: "device integrity",
			run: func(t *testing.T, h *SessionHandler, d *fakeDecoder) {
				postSession(h, sessionBody(t, h, d, "i-basic", func(p *attest.Payload) {
					p.DeviceIntegrity.DeviceRecognitionVerdict = []string{"MEETS_BASIC_INTEGRITY"}
				}))
			},
			want: metrics.DeviceIntegrity,
		},
		{
			name: "cert mismatch",
			run: func(t *testing.T, h *SessionHandler, d *fakeDecoder) {
				postSession(h, sessionBody(t, h, d, "i-cert", func(p *attest.Payload) {
					p.AppIntegrity.CertificateSha256Digest = []string{"other"}
				}))
			},
			want: metrics.CertMismatch,
		},
		{
			name: "banned",
			run: func(t *testing.T, h *SessionHandler, d *fakeDecoder) {
				hash := attest.InstallHash("i-banned")
				if err := h.Store.TouchInstall(context.Background(), hash, now, store.InstallMeta{}); err != nil {
					t.Fatalf("touch: %v", err)
				}
				if err := h.Store.Ban(context.Background(), hash, "test"); err != nil {
					t.Fatalf("ban: %v", err)
				}
				postSession(h, sessionBody(t, h, d, "i-banned", nil))
			},
			want: metrics.Banned,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			decoder := &fakeDecoder{}
			h := newTestHandler(t, decoder, now)
			counter := newFakeCounter()
			h.Metrics = counter

			c.run(t, h, decoder)

			if got := counter.n(metrics.SessionOutcome, c.want); got != 1 {
				t.Fatalf("session_outcome/%s = %d, want 1 (all: %v)", c.want, got, counter.got)
			}
			if got := counter.total(metrics.SessionOutcome); got != 1 {
				t.Fatalf("session_outcome total = %d, want exactly 1 (all: %v)", got, counter.got)
			}
		})
	}
}

func TestChallengeCountsRateLimit(t *testing.T) {
	now := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	h := newTestHandler(t, &fakeDecoder{}, now)
	counter := newFakeCounter()
	h.Metrics = counter
	h.ChallengeLimiter = NewChallengeLimiter(1)

	for i := 0; i < 2; i++ {
		h.Challenge(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/v1/challenge", nil))
	}

	if got := counter.n(metrics.SessionOutcome, metrics.ChallengeRateLimited); got != 1 {
		t.Fatalf("challenge_rate_limited = %d, want 1 (all: %v)", got, counter.got)
	}
	if got := counter.total(metrics.SessionOutcome); got != 1 {
		t.Fatalf("session_outcome total = %d, want 1: a granted challenge is not counted", got)
	}
}
