package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/ahmedsadman/pawlet/server/internal/attest"
	"github.com/ahmedsadman/pawlet/server/internal/store"
	"github.com/ahmedsadman/pawlet/server/internal/token"
)

// fakeDecoder implements attest.Decoder for testing.
type fakeDecoder struct {
	payload     attest.Payload
	err         error
	callCount   int
	shouldError bool
}

func (d *fakeDecoder) Decode(_ context.Context, _ string) (attest.Payload, error) {
	d.callCount++
	if d.shouldError {
		return attest.Payload{}, d.err
	}
	return d.payload, nil
}

func (d *fakeDecoder) reset() {
	d.callCount = 0
}

// newTestHandler builds a SessionHandler with real components except the decoder.
func newTestHandler(t *testing.T, decoder *fakeDecoder, now time.Time) *SessionHandler {
	t.Helper()

	st, err := store.Open(t.TempDir() + "/test.db")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })

	issuer := token.New([]byte("test-secret-key-for-session-handler"), 24*time.Hour)
	challenges := attest.NewChallenges(2*time.Minute, func() time.Time { return now })

	policy := attest.Policy{
		PackageName: "com.example.pawlet",
		CertDigests: []string{"test-cert-digest"},
		MaxAge:      5 * time.Minute,
	}

	return &SessionHandler{
		Challenges: challenges,
		Decoder:    decoder,
		Issuer:     issuer,
		Store:      st,
		Policy:     policy,
		Now:        func() time.Time { return now },
		Logger:     discardLogger(),
	}
}

// genuinePayload returns a valid Play Integrity payload matching the test policy.
func genuinePayload(installID, challenge string, issuedAt time.Time) attest.Payload {
	var p attest.Payload
	p.RequestDetails.RequestPackageName = "com.example.pawlet"
	p.RequestDetails.RequestHash = attest.RequestHash(installID, challenge)
	p.RequestDetails.TimestampMillis = strconv.FormatInt(issuedAt.UnixMilli(), 10)
	p.AppIntegrity.AppRecognitionVerdict = "PLAY_RECOGNIZED"
	p.AppIntegrity.PackageName = "com.example.pawlet"
	p.AppIntegrity.CertificateSha256Digest = []string{"test-cert-digest"}
	p.DeviceIntegrity.DeviceRecognitionVerdict = []string{"MEETS_DEVICE_INTEGRITY"}
	return p
}

func TestChallengeReturns64CharHex(t *testing.T) {
	now := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	handler := newTestHandler(t, &fakeDecoder{}, now)

	rec := httptest.NewRecorder()
	handler.Challenge(rec, httptest.NewRequest(http.MethodPost, "/v1/challenge", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}

	var resp challengeResponse
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	if len(resp.Challenge) != 64 {
		t.Fatalf("challenge length = %d, want 64", len(resp.Challenge))
	}
	for _, r := range resp.Challenge {
		if (r < '0' || r > '9') && (r < 'a' || r > 'f') {
			t.Fatalf("challenge contains non-hex character: %c", r)
		}
	}
}

func TestGenuineVerdictMintsToken(t *testing.T) {
	now := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	installID := "install-123"

	decoder := &fakeDecoder{
		payload: genuinePayload(installID, "challenge-value", now),
	}
	handler := newTestHandler(t, decoder, now)

	// Issue a challenge first.
	challenge, err := handler.Challenges.Issue()
	if err != nil {
		t.Fatalf("issue challenge: %v", err)
	}

	// Update the payload to use the real challenge.
	decoder.payload = genuinePayload(installID, challenge, now)

	reqBody, _ := json.Marshal(sessionRequest{
		InstallID:      installID,
		Challenge:      challenge,
		IntegrityToken: "fake-token",
	})

	rec := httptest.NewRecorder()
	handler.Session(rec, httptest.NewRequest(http.MethodPost, "/v1/session", bytes.NewReader(reqBody)))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body: %s", rec.Code, rec.Body.String())
	}

	var resp sessionResponse
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	if resp.Token == "" {
		t.Fatal("response missing token")
	}

	// Verify the token is valid.
	installHash, err := handler.Issuer.Verify(resp.Token, now)
	if err != nil {
		t.Fatalf("verify minted token: %v", err)
	}
	if installHash != attest.InstallHash(installID) {
		t.Fatalf("token subject = %s, want %s", installHash, attest.InstallHash(installID))
	}

	// Verify expiresAt is in the future.
	if resp.ExpiresAt <= now.Unix() {
		t.Fatalf("expiresAt = %d, want > %d", resp.ExpiresAt, now.Unix())
	}

	expectedExpiry := now.Add(handler.Issuer.TTL()).Unix()
	if resp.ExpiresAt != expectedExpiry {
		t.Fatalf("expiresAt = %d, want %d", resp.ExpiresAt, expectedExpiry)
	}

	// Verify the install was recorded under its hash.
	installHash = attest.InstallHash(installID)
	install, err := handler.Store.Install(context.Background(), installHash)
	if err != nil {
		t.Fatalf("read install: %v", err)
	}
	if install.IDHash != installHash {
		t.Fatalf("install id_hash = %s, want %s", install.IDHash, installHash)
	}
}

func TestReplayedChallengeIs403(t *testing.T) {
	now := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	installID := "install-456"

	decoder := &fakeDecoder{
		payload: genuinePayload(installID, "challenge-value", now),
	}
	handler := newTestHandler(t, decoder, now)

	// Issue a challenge.
	challenge, err := handler.Challenges.Issue()
	if err != nil {
		t.Fatalf("issue challenge: %v", err)
	}

	decoder.payload = genuinePayload(installID, challenge, now)

	reqBody, _ := json.Marshal(sessionRequest{
		InstallID:      installID,
		Challenge:      challenge,
		IntegrityToken: "fake-token",
	})

	// First attempt should succeed.
	rec1 := httptest.NewRecorder()
	handler.Session(rec1, httptest.NewRequest(http.MethodPost, "/v1/session", bytes.NewReader(reqBody)))
	if rec1.Code != http.StatusOK {
		t.Fatalf("first attempt: status = %d, want 200", rec1.Code)
	}

	// Second attempt with the same challenge should fail.
	rec2 := httptest.NewRecorder()
	handler.Session(rec2, httptest.NewRequest(http.MethodPost, "/v1/session", bytes.NewReader(reqBody)))
	if rec2.Code != http.StatusForbidden {
		t.Fatalf("second attempt: status = %d, want 403", rec2.Code)
	}

	var errBody errorBody
	if err := json.NewDecoder(rec2.Body).Decode(&errBody); err != nil {
		t.Fatalf("decode error response: %v", err)
	}
	if errBody.Error != "attestation_failed" {
		t.Fatalf("error code = %s, want attestation_failed", errBody.Error)
	}
}

func TestFailedVerdictIs403(t *testing.T) {
	now := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	installID := "install-789"

	// Create a payload that fails device integrity.
	payload := genuinePayload(installID, "challenge-value", now)
	payload.DeviceIntegrity.DeviceRecognitionVerdict = []string{"MEETS_BASIC_INTEGRITY"}

	decoder := &fakeDecoder{payload: payload}
	handler := newTestHandler(t, decoder, now)

	challenge, err := handler.Challenges.Issue()
	if err != nil {
		t.Fatalf("issue challenge: %v", err)
	}

	// Update the payload to use the real challenge but still fail verification.
	payload = genuinePayload(installID, challenge, now)
	payload.DeviceIntegrity.DeviceRecognitionVerdict = []string{"MEETS_BASIC_INTEGRITY"}
	decoder.payload = payload

	reqBody, _ := json.Marshal(sessionRequest{
		InstallID:      installID,
		Challenge:      challenge,
		IntegrityToken: "fake-token",
	})

	rec := httptest.NewRecorder()
	handler.Session(rec, httptest.NewRequest(http.MethodPost, "/v1/session", bytes.NewReader(reqBody)))

	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rec.Code)
	}

	var errBody errorBody
	if err := json.NewDecoder(rec.Body).Decode(&errBody); err != nil {
		t.Fatalf("decode error response: %v", err)
	}
	if errBody.Error != "attestation_failed" {
		t.Fatalf("error code = %s, want attestation_failed", errBody.Error)
	}

	// Verify the error body does NOT contain the verification error text.
	if strings.Contains(rec.Body.String(), "device integrity") {
		t.Fatal("error response leaks verification error text")
	}
}

func TestDecoderErrorIs503(t *testing.T) {
	now := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	installID := "install-decode-fail"

	// Test both decode error sentinels.
	testCases := []struct {
		name string
		err  error
	}{
		{"unreachable", attest.ErrDecodeUnreachable},
		{"rejected", attest.ErrDecodeRejected},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			decoder := &fakeDecoder{
				shouldError: true,
				err:         tc.err,
			}
			handler := newTestHandler(t, decoder, now)

			challenge, err := handler.Challenges.Issue()
			if err != nil {
				t.Fatalf("issue challenge: %v", err)
			}

			reqBody, _ := json.Marshal(sessionRequest{
				InstallID:      installID,
				Challenge:      challenge,
				IntegrityToken: "fake-token",
			})

			rec := httptest.NewRecorder()
			handler.Session(rec, httptest.NewRequest(http.MethodPost, "/v1/session", bytes.NewReader(reqBody)))

			// Both decode errors MUST map to 503, not 403.
			if rec.Code != http.StatusServiceUnavailable {
				t.Fatalf("status = %d, want 503 for %s", rec.Code, tc.name)
			}

			var errBody errorBody
			if err := json.NewDecoder(rec.Body).Decode(&errBody); err != nil {
				t.Fatalf("decode error response: %v", err)
			}
			if errBody.Error != "attestation_unavailable" {
				t.Fatalf("error code = %s, want attestation_unavailable", errBody.Error)
			}
		})
	}
}

func TestBannedInstallIs403(t *testing.T) {
	now := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	installID := "install-banned"

	decoder := &fakeDecoder{
		payload: genuinePayload(installID, "challenge-value", now),
	}
	handler := newTestHandler(t, decoder, now)

	// Ban the install first.
	installHash := attest.InstallHash(installID)
	if err := handler.Store.TouchInstall(context.Background(), installHash, now); err != nil {
		t.Fatalf("touch install: %v", err)
	}
	if err := handler.Store.Ban(context.Background(), installHash, "test ban"); err != nil {
		t.Fatalf("ban install: %v", err)
	}

	// Now attempt a session with a genuine verdict.
	challenge, err := handler.Challenges.Issue()
	if err != nil {
		t.Fatalf("issue challenge: %v", err)
	}

	decoder.payload = genuinePayload(installID, challenge, now)

	reqBody, _ := json.Marshal(sessionRequest{
		InstallID:      installID,
		Challenge:      challenge,
		IntegrityToken: "fake-token",
	})

	rec := httptest.NewRecorder()
	handler.Session(rec, httptest.NewRequest(http.MethodPost, "/v1/session", bytes.NewReader(reqBody)))

	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rec.Code)
	}

	var errBody errorBody
	if err := json.NewDecoder(rec.Body).Decode(&errBody); err != nil {
		t.Fatalf("decode error response: %v", err)
	}
	if errBody.Error != "banned" {
		t.Fatalf("error code = %s, want banned", errBody.Error)
	}
}

func TestMalformedJSONIs400(t *testing.T) {
	now := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	handler := newTestHandler(t, &fakeDecoder{}, now)

	reqBody := bytes.NewReader([]byte(`{"installId": "missing-quote}`))
	rec := httptest.NewRecorder()
	handler.Session(rec, httptest.NewRequest(http.MethodPost, "/v1/session", reqBody))

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}

	var errBody errorBody
	if err := json.NewDecoder(rec.Body).Decode(&errBody); err != nil {
		t.Fatalf("decode error response: %v", err)
	}
	if errBody.Error != "bad_request" {
		t.Fatalf("error code = %s, want bad_request", errBody.Error)
	}
}

func TestMissingInstallIDIs400(t *testing.T) {
	now := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	handler := newTestHandler(t, &fakeDecoder{}, now)

	reqBody, _ := json.Marshal(sessionRequest{
		InstallID:      "", // missing
		Challenge:      "challenge-value",
		IntegrityToken: "fake-token",
	})

	rec := httptest.NewRecorder()
	handler.Session(rec, httptest.NewRequest(http.MethodPost, "/v1/session", bytes.NewReader(reqBody)))

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}

	var errBody errorBody
	if err := json.NewDecoder(rec.Body).Decode(&errBody); err != nil {
		t.Fatalf("decode error response: %v", err)
	}
	if errBody.Error != "bad_request" {
		t.Fatalf("error code = %s, want bad_request", errBody.Error)
	}
}

func TestDecodeNotCalledWhenChallengeInvalid(t *testing.T) {
	now := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	installID := "install-no-decode"

	decoder := &fakeDecoder{
		payload: genuinePayload(installID, "unissued-challenge", now),
	}
	handler := newTestHandler(t, decoder, now)

	// Submit a request with an unissued challenge.
	reqBody, _ := json.Marshal(sessionRequest{
		InstallID:      installID,
		Challenge:      "unissued-challenge-value",
		IntegrityToken: "fake-token",
	})

	rec := httptest.NewRecorder()
	handler.Session(rec, httptest.NewRequest(http.MethodPost, "/v1/session", bytes.NewReader(reqBody)))

	// Verify the request failed with 403.
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rec.Code)
	}

	// The critical assertion: the decoder was NEVER invoked.
	if decoder.callCount != 0 {
		t.Fatalf("decoder was called %d times, want 0 (proves ordering protects Google quota)", decoder.callCount)
	}
}

func TestFirstTimeInstallNotBannedContinues(t *testing.T) {
	now := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	installID := "install-first-time"

	decoder := &fakeDecoder{
		payload: genuinePayload(installID, "challenge-value", now),
	}
	handler := newTestHandler(t, decoder, now)

	// Issue a challenge.
	challenge, err := handler.Challenges.Issue()
	if err != nil {
		t.Fatalf("issue challenge: %v", err)
	}

	decoder.payload = genuinePayload(installID, challenge, now)

	// Verify the install does NOT exist yet.
	installHash := attest.InstallHash(installID)
	_, err = handler.Store.Install(context.Background(), installHash)
	if !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("install should not exist yet, got err: %v", err)
	}

	// Submit the session request.
	reqBody, _ := json.Marshal(sessionRequest{
		InstallID:      installID,
		Challenge:      challenge,
		IntegrityToken: "fake-token",
	})

	rec := httptest.NewRecorder()
	handler.Session(rec, httptest.NewRequest(http.MethodPost, "/v1/session", bytes.NewReader(reqBody)))

	// First-time install should succeed (ErrNotFound is NOT an error).
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body: %s", rec.Code, rec.Body.String())
	}

	// Verify the install was created.
	install, err := handler.Store.Install(context.Background(), installHash)
	if err != nil {
		t.Fatalf("install should exist now: %v", err)
	}
	if install.Banned {
		t.Fatal("first-time install should not be banned")
	}
}

func TestChallengeConsumedExactlyOnceEvenOnLaterFailure(t *testing.T) {
	now := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	installID := "install-consume-once"

	// Create a payload that will fail verification.
	payload := genuinePayload(installID, "challenge-value", now)
	payload.AppIntegrity.AppRecognitionVerdict = "UNRECOGNIZED"

	decoder := &fakeDecoder{payload: payload}
	handler := newTestHandler(t, decoder, now)

	// Issue a challenge.
	challenge, err := handler.Challenges.Issue()
	if err != nil {
		t.Fatalf("issue challenge: %v", err)
	}

	// Update payload to use real challenge but still fail verification.
	payload = genuinePayload(installID, challenge, now)
	payload.AppIntegrity.AppRecognitionVerdict = "UNRECOGNIZED"
	decoder.payload = payload

	reqBody, _ := json.Marshal(sessionRequest{
		InstallID:      installID,
		Challenge:      challenge,
		IntegrityToken: "fake-token",
	})

	// First attempt should fail verification, not challenge.
	rec1 := httptest.NewRecorder()
	handler.Session(rec1, httptest.NewRequest(http.MethodPost, "/v1/session", bytes.NewReader(reqBody)))
	if rec1.Code != http.StatusForbidden {
		t.Fatalf("first attempt: status = %d, want 403", rec1.Code)
	}

	// The challenge was consumed on the first attempt even though verification
	// failed. A second attempt should fail at challenge consume, not decoder.
	decoder.reset()
	rec2 := httptest.NewRecorder()
	handler.Session(rec2, httptest.NewRequest(http.MethodPost, "/v1/session", bytes.NewReader(reqBody)))
	if rec2.Code != http.StatusForbidden {
		t.Fatalf("second attempt: status = %d, want 403", rec2.Code)
	}

	// Verify the decoder was NOT called on the second attempt.
	if decoder.callCount != 0 {
		t.Fatalf("decoder called %d times on replay, want 0 (challenge was consumed)", decoder.callCount)
	}
}

func TestChallengeRateLimitIs429(t *testing.T) {
	now := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	handler := newTestHandler(t, &fakeDecoder{}, now)

	// Wire in a limiter with capacity 1.
	handler.ChallengeLimiter = newHourlyLimiter(1, func() time.Time { return now })

	// First request should succeed.
	req1 := httptest.NewRequest(http.MethodPost, "/v1/challenge", nil)
	req1.RemoteAddr = "192.0.2.1:12345"
	rec1 := httptest.NewRecorder()
	handler.Challenge(rec1, req1)
	if rec1.Code != http.StatusOK {
		t.Fatalf("first request: status = %d, want 200", rec1.Code)
	}

	// Second request from the same address should be rate limited.
	req2 := httptest.NewRequest(http.MethodPost, "/v1/challenge", nil)
	req2.RemoteAddr = "192.0.2.1:12345"
	rec2 := httptest.NewRecorder()
	handler.Challenge(rec2, req2)
	if rec2.Code != http.StatusTooManyRequests {
		t.Fatalf("second request: status = %d, want 429", rec2.Code)
	}

	var errBody errorBody
	if err := json.NewDecoder(rec2.Body).Decode(&errBody); err != nil {
		t.Fatalf("decode error response: %v", err)
	}
	if errBody.Error != "rate_limited" {
		t.Fatalf("error code = %s, want rate_limited", errBody.Error)
	}

	// Verify the Retry-After header is present.
	retryAfter := rec2.Header().Get("Retry-After")
	if retryAfter == "" {
		t.Fatal("Retry-After header missing")
	}
}
