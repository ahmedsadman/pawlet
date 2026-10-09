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
