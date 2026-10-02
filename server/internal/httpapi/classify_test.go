package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/ahmedsadman/pawlet/server/internal/llm"
	"github.com/ahmedsadman/pawlet/server/internal/quota"
	"github.com/ahmedsadman/pawlet/server/internal/store"
	"github.com/ahmedsadman/pawlet/server/internal/token"
)

// fakeClassifier records invocations and returns a canned response.
type fakeClassifier struct {
	calls    int
	response llm.Response
	err      error
}

func (f *fakeClassifier) Classify(ctx context.Context, in llm.Request) (llm.Response, error) {
	f.calls++
	return f.response, f.err
}

// noopSink implements quota.Sink for tests.
type noopSink struct{}

func (noopSink) PersistUsage(ctx context.Context, deltas []quota.Delta) error {
	return nil
}

func (noopSink) LoadUsage(ctx context.Context, day string) (map[string]int64, error) {
	return nil, nil
}

// testHarness builds a ClassifyHandler with real dependencies and a fake classifier.
type testHarness struct {
	handler    *ClassifyHandler
	store      *store.Store
	issuer     *token.Issuer
	limiter    *quota.Limiter
	classifier *fakeClassifier
	now        time.Time
	logger     *slog.Logger
}

func newTestHarness(t *testing.T) *testHarness {
	t.Helper()

	dbPath := t.TempDir() + "/test.db"
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("store.Open() failed: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })

	issuer := token.New([]byte("test-secret"), 24*time.Hour)

	now := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	limiter := quota.New(quota.Limits{
		Daily:       100,
		Burst:       10,
		GlobalDaily: 1000,
	}, noopSink{}, func() time.Time { return now })

	classifier := &fakeClassifier{
		response: llm.Response{
			Result: llm.ClassifyResult{
				Category: llm.CategoryTransaction,
				Transaction: &llm.Transaction{
					Amount:           ptrStr("50.00"),
					OriginalAmount:   ptrStr("50.00"),
					TransactionType:  ptrStr("expense"),
					OriginalCurrency: ptrStr("BDT"),
				},
			},
			TotalTokens: 123,
		},
	}

	logger := discardLogger()

	h := &ClassifyHandler{
		Classifier: classifier,
		Issuer:     issuer,
		Store:      st,
		Limiter:    limiter,
		Now:        func() time.Time { return now },
		Logger:     logger,
	}

	return &testHarness{
		handler:    h,
		store:      st,
		issuer:     issuer,
		limiter:    limiter,
		classifier: classifier,
		now:        now,
		logger:     logger,
	}
}

func ptrStr(s string) *string { return &s }

// mintToken creates a session token for the given install hash.
func (h *testHarness) mintToken(installHash string) string {
	tok, err := h.issuer.Mint(installHash, h.now)
	if err != nil {
		panic(err)
	}
	return tok
}

// touchInstall ensures the install exists in the store.
func (h *testHarness) touchInstall(installHash string) {
	if err := h.store.TouchInstall(context.Background(), installHash, h.now); err != nil {
		panic(err)
	}
}

// classifyRequestBody builds a valid classify request body.
func classifyRequestBody(sender, content, currency string) io.Reader {
	payload := map[string]string{
		"sender":   sender,
		"content":  content,
		"currency": currency,
	}
	b, _ := json.Marshal(payload)
	return bytes.NewReader(b)
}

func TestClassifySuccess(t *testing.T) {
	h := newTestHarness(t)
	installHash := strings.Repeat("a", 64) // SHA-256 hex is 64 chars
	h.touchInstall(installHash)
	sessionToken := h.mintToken(installHash)

	req := httptest.NewRequest(http.MethodPost, "/v1/classify",
		classifyRequestBody("BANK", "Your balance is 1000 BDT", "BDT"))
	req.Header.Set("Authorization", "Bearer "+sessionToken)
	rec := httptest.NewRecorder()

	h.handler.Classify(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body: %s", rec.Code, rec.Body.String())
	}

	// Decode the response and verify it contains the monetary value as a string.
	var result llm.ClassifyResult
	if err := json.NewDecoder(rec.Body).Decode(&result); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}
	// Category is not unmarshaled (json:"-" tag), so check the transaction field.
	if result.Transaction == nil {
		t.Fatalf("transaction is nil, want non-nil for transaction category")
	}
	if result.Transaction.Amount == nil {
		t.Fatalf("transaction.amount is nil")
	}
	if *result.Transaction.Amount != "50.00" {
		t.Fatalf("transaction.amount = %q, want 50.00 as a string", *result.Transaction.Amount)
	}

	// Verify the classifier was called.
	if h.classifier.calls != 1 {
		t.Fatalf("classifier.calls = %d, want 1", h.classifier.calls)
	}
}

func TestClassifyMissingBearerHeader(t *testing.T) {
	h := newTestHarness(t)
	req := httptest.NewRequest(http.MethodPost, "/v1/classify",
		classifyRequestBody("BANK", "content", "BDT"))
	rec := httptest.NewRecorder()

	h.handler.Classify(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}

	var errResp errorBody
	if err := json.NewDecoder(rec.Body).Decode(&errResp); err != nil {
		t.Fatalf("failed to decode error: %v", err)
	}
	if errResp.Error != "unauthorized" {
		t.Fatalf("error = %q, want unauthorized", errResp.Error)
	}
}

func TestClassifyMalformedBearerHeader(t *testing.T) {
	h := newTestHarness(t)
	req := httptest.NewRequest(http.MethodPost, "/v1/classify",
		classifyRequestBody("BANK", "content", "BDT"))
	req.Header.Set("Authorization", "sometoken")
	rec := httptest.NewRecorder()

	h.handler.Classify(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
}

func TestClassifyExpiredToken(t *testing.T) {
	h := newTestHarness(t)
	installHash := strings.Repeat("b", 64)
	h.touchInstall(installHash)

	// Mint a token in the past.
	past := h.now.Add(-25 * time.Hour)
	expiredToken, err := h.issuer.Mint(installHash, past)
	if err != nil {
		t.Fatalf("failed to mint expired token: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/v1/classify",
		classifyRequestBody("BANK", "content", "BDT"))
	req.Header.Set("Authorization", "Bearer "+expiredToken)
	rec := httptest.NewRecorder()

	h.handler.Classify(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
}

func TestClassifyTokenForUnknownInstall(t *testing.T) {
	h := newTestHarness(t)
	installHash := strings.Repeat("c", 64)
	// Do NOT touch the install — it's unknown.
	sessionToken := h.mintToken(installHash)

	req := httptest.NewRequest(http.MethodPost, "/v1/classify",
		classifyRequestBody("BANK", "content", "BDT"))
	req.Header.Set("Authorization", "Bearer "+sessionToken)
	rec := httptest.NewRecorder()

	h.handler.Classify(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401 (stale token)", rec.Code)
	}
}

func TestClassifyBannedInstall(t *testing.T) {
	h := newTestHarness(t)
	installHash := strings.Repeat("d", 64)
	h.touchInstall(installHash)
	if err := h.store.Ban(context.Background(), installHash, "test ban"); err != nil {
		t.Fatalf("failed to ban install: %v", err)
	}
	sessionToken := h.mintToken(installHash)

	req := httptest.NewRequest(http.MethodPost, "/v1/classify",
		classifyRequestBody("BANK", "content", "BDT"))
	req.Header.Set("Authorization", "Bearer "+sessionToken)
	rec := httptest.NewRecorder()

	h.handler.Classify(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rec.Code)
	}

	var errResp errorBody
	if err := json.NewDecoder(rec.Body).Decode(&errResp); err != nil {
		t.Fatalf("failed to decode error: %v", err)
	}
	if errResp.Error != "banned" {
		t.Fatalf("error = %q, want banned", errResp.Error)
	}
}

func TestClassifyContentTooLong(t *testing.T) {
	h := newTestHarness(t)
	installHash := strings.Repeat("e", 64)
	h.touchInstall(installHash)
	sessionToken := h.mintToken(installHash)

	longContent := strings.Repeat("x", 2049)
	req := httptest.NewRequest(http.MethodPost, "/v1/classify",
		classifyRequestBody("BANK", longContent, "BDT"))
	req.Header.Set("Authorization", "Bearer "+sessionToken)
	rec := httptest.NewRecorder()

	h.handler.Classify(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
}

func TestClassifyEmptyContent(t *testing.T) {
	h := newTestHarness(t)
	installHash := strings.Repeat("f", 64)
	h.touchInstall(installHash)
	sessionToken := h.mintToken(installHash)

	req := httptest.NewRequest(http.MethodPost, "/v1/classify",
		classifyRequestBody("BANK", "", "BDT"))
	req.Header.Set("Authorization", "Bearer "+sessionToken)
	rec := httptest.NewRecorder()

	h.handler.Classify(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
}

func TestClassifyInvalidCurrency(t *testing.T) {
	h := newTestHarness(t)
	installHash := strings.Repeat("g", 64)
	h.touchInstall(installHash)
	sessionToken := h.mintToken(installHash)

	req := httptest.NewRequest(http.MethodPost, "/v1/classify",
		classifyRequestBody("BANK", "content", "BANGLA"))
	req.Header.Set("Authorization", "Bearer "+sessionToken)
	rec := httptest.NewRecorder()

	h.handler.Classify(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
}

func TestClassifyQuotaExhausted(t *testing.T) {
	h := newTestHarness(t)
	installHash := strings.Repeat("h", 64)
	h.touchInstall(installHash)
	sessionToken := h.mintToken(installHash)

	// Exhaust the daily quota.
	for i := 0; i < 100; i++ {
		h.limiter.Admit(installHash)
	}

	req := httptest.NewRequest(http.MethodPost, "/v1/classify",
		classifyRequestBody("BANK", "content", "BDT"))
	req.Header.Set("Authorization", "Bearer "+sessionToken)
	rec := httptest.NewRecorder()

	h.handler.Classify(rec, req)

	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429", rec.Code)
	}

	retryAfter := rec.Header().Get("Retry-After")
	if retryAfter == "" {
		t.Fatalf("Retry-After header is missing")
	}

	// Verify the classifier was NOT called.
	if h.classifier.calls != 0 {
		t.Fatalf("classifier.calls = %d, want 0 (quota denied before LLM)", h.classifier.calls)
	}
}

func TestClassifyGlobalCapReached(t *testing.T) {
	h := newTestHarness(t)

	// Exhaust the global cap (1000 calls/day). Admit 1000 calls from different
	// installs so the global counter hits the limit, then try one more.
	for i := 0; i < 1000; i++ {
		// Use unique hashes to avoid per-install limits.
		fakeHash := strings.Repeat("0", 62) + string(rune('a'+i/26)) + string(rune('a'+i%26))
		decision := h.limiter.Admit(fakeHash)
		if !decision.Allowed {
			t.Fatalf("unexpected denial at iteration %d: %+v", i, decision)
		}
	}

	installHash := strings.Repeat("i", 64)
	h.touchInstall(installHash)
	sessionToken := h.mintToken(installHash)

	req := httptest.NewRequest(http.MethodPost, "/v1/classify",
		classifyRequestBody("BANK", "content", "BDT"))
	req.Header.Set("Authorization", "Bearer "+sessionToken)
	rec := httptest.NewRecorder()

	h.handler.Classify(rec, req)

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", rec.Code)
	}

	var errResp errorBody
	if err := json.NewDecoder(rec.Body).Decode(&errResp); err != nil {
		t.Fatalf("failed to decode error: %v", err)
	}
	if errResp.Error != "capacity" {
		t.Fatalf("error = %q, want capacity", errResp.Error)
	}

	// Verify the classifier was NOT called.
	if h.classifier.calls != 0 {
		t.Fatalf("classifier.calls = %d, want 0 (global cap denied before LLM)", h.classifier.calls)
	}
}

func TestClassifyUpstream429(t *testing.T) {
	h := newTestHarness(t)
	installHash := strings.Repeat("j", 64)
	h.touchInstall(installHash)
	sessionToken := h.mintToken(installHash)

	// Configure the classifier to return a 429.
	h.classifier.err = &llm.CallError{
		Status:         429,
		Retryable:      true,
		RetryAfter:     30 * time.Second,
		ResetAtEpochMs: 1700000000000,
	}

	req := httptest.NewRequest(http.MethodPost, "/v1/classify",
		classifyRequestBody("BANK", "content", "BDT"))
	req.Header.Set("Authorization", "Bearer "+sessionToken)
	rec := httptest.NewRecorder()

	h.handler.Classify(rec, req)

	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429", rec.Code)
	}

	if rec.Header().Get("Retry-After") != "30" {
		t.Fatalf("Retry-After = %q, want 30", rec.Header().Get("Retry-After"))
	}
	if rec.Header().Get("X-RateLimit-Reset") != "1700000000000" {
		t.Fatalf("X-RateLimit-Reset = %q, want 1700000000000", rec.Header().Get("X-RateLimit-Reset"))
	}
}

func TestClassifyUpstreamRetryable(t *testing.T) {
	h := newTestHarness(t)
	installHash := strings.Repeat("k", 64)
	h.touchInstall(installHash)
	sessionToken := h.mintToken(installHash)

	// Configure the classifier to return a retryable error (502).
	h.classifier.err = &llm.CallError{
		Status:    502,
		Retryable: true,
		Message:   "bad gateway",
	}

	req := httptest.NewRequest(http.MethodPost, "/v1/classify",
		classifyRequestBody("BANK", "content", "BDT"))
	req.Header.Set("Authorization", "Bearer "+sessionToken)
	rec := httptest.NewRecorder()

	h.handler.Classify(rec, req)

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", rec.Code)
	}

	var errResp errorBody
	if err := json.NewDecoder(rec.Body).Decode(&errResp); err != nil {
		t.Fatalf("failed to decode error: %v", err)
	}
	if errResp.Error != "upstream" {
		t.Fatalf("error = %q, want upstream", errResp.Error)
	}
}

func TestClassifyUpstreamFatal(t *testing.T) {
	h := newTestHarness(t)
	installHash := strings.Repeat("l", 64)
	h.touchInstall(installHash)
	sessionToken := h.mintToken(installHash)

	// Configure the classifier to return a fatal error (400).
	h.classifier.err = &llm.CallError{
		Status:    400,
		Retryable: false,
		Message:   "bad request",
	}

	req := httptest.NewRequest(http.MethodPost, "/v1/classify",
		classifyRequestBody("BANK", "content", "BDT"))
	req.Header.Set("Authorization", "Bearer "+sessionToken)
	rec := httptest.NewRecorder()

	h.handler.Classify(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}

	var errResp errorBody
	if err := json.NewDecoder(rec.Body).Decode(&errResp); err != nil {
		t.Fatalf("failed to decode error: %v", err)
	}
	if errResp.Error != "upstream_rejected" {
		t.Fatalf("error = %q, want upstream_rejected", errResp.Error)
	}
}

func TestClassifyPrivacy(t *testing.T) {
	h := newTestHarness(t)

	// Capture logs into a buffer.
	var logBuf bytes.Buffer
	h.handler.Logger = slog.New(slog.NewTextHandler(&logBuf, nil))

	installHash := strings.Repeat("m", 64)
	h.touchInstall(installHash)
	sessionToken := h.mintToken(installHash)

	distinctiveSender := "UNIQUE-BANK-9876"
	distinctiveContent := "SECRET-SMS-TEXT-ABCDEF"

	req := httptest.NewRequest(http.MethodPost, "/v1/classify",
		classifyRequestBody(distinctiveSender, distinctiveContent, "BDT"))
	req.Header.Set("Authorization", "Bearer "+sessionToken)
	rec := httptest.NewRecorder()

	h.handler.Classify(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body: %s", rec.Code, rec.Body.String())
	}

	logOutput := logBuf.String()

	// Verify the content, sender, and full install hash do NOT appear.
	if strings.Contains(logOutput, distinctiveContent) {
		t.Fatalf("log contains the message content: %s", logOutput)
	}
	if strings.Contains(logOutput, distinctiveSender) {
		t.Fatalf("log contains the sender: %s", logOutput)
	}
	if strings.Contains(logOutput, installHash) {
		t.Fatalf("log contains the full install hash: %s", logOutput)
	}

	// Verify the 8-character prefix DOES appear.
	prefix := installHash[:8]
	if !strings.Contains(logOutput, prefix) {
		t.Fatalf("log is missing the 8-character hash prefix %q: %s", prefix, logOutput)
	}
}

func TestClassifyEmptyBearerToken(t *testing.T) {
	h := newTestHarness(t)
	req := httptest.NewRequest(http.MethodPost, "/v1/classify",
		classifyRequestBody("BANK", "content", "BDT"))
	req.Header.Set("Authorization", "Bearer ")
	rec := httptest.NewRecorder()

	h.handler.Classify(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401 for empty bearer token", rec.Code)
	}
}

func TestClassifyRejectsTokenWithShortSubject(t *testing.T) {
	h := newTestHarness(t)
	// Signed with our key but the subject is not a SHA-256 hex hash.
	short := h.mintToken("abc")

	req := httptest.NewRequest(http.MethodPost, "/v1/classify",
		classifyRequestBody("BANK", "balance 1000 BDT", "BDT"))
	req.Header.Set("Authorization", "Bearer "+short)
	rec := httptest.NewRecorder()

	h.handler.Classify(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
	if h.classifier.calls != 0 {
		t.Fatalf("classifier called %d times, want 0", h.classifier.calls)
	}
}
