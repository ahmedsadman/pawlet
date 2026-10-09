package admin

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
	"time"

	"github.com/ahmedsadman/pawlet/server/internal/store"
)

var testNow = time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC)

type testEnv struct {
	store   *store.Store
	handler http.Handler
	dbPath  string
}

func newTestEnv(t *testing.T) *testEnv {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "admin.db")
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("store.Open() error = %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })

	srv := New(Options{
		Store:         st,
		PasswordHash:  hashForTests(t),
		SessionSecret: []byte(strings.Repeat("k", 32)),
		Now:           func() time.Time { return testNow },
		Web: fstest.MapFS{
			"index.html":    {Data: []byte("<!doctype html><title>pawlet</title>")},
			"assets/app.js": {Data: []byte("console.log(1)")},
		},
	})
	return &testEnv{store: st, handler: srv.Handler(), dbPath: dbPath}
}

func (e *testEnv) do(method, path, body string, cookie *http.Cookie) *httptest.ResponseRecorder {
	var req *http.Request
	if body == "" {
		req = httptest.NewRequest(method, path, nil)
	} else {
		req = httptest.NewRequest(method, path, strings.NewReader(body))
	}
	if method == http.MethodPost {
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Origin", "https://example.com")
	}
	if cookie != nil {
		req.AddCookie(cookie)
	}
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	return rec
}

func (e *testEnv) login(t *testing.T) *http.Cookie {
	t.Helper()
	rec := e.do(http.MethodPost, "/api/login", `{"password":"correct horse"}`, nil)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("login status = %d, body %s", rec.Code, rec.Body.String())
	}
	return rec.Result().Cookies()[0]
}

func errorCode(t *testing.T, rec *httptest.ResponseRecorder) string {
	t.Helper()
	var b errorBody
	if err := json.NewDecoder(rec.Body).Decode(&b); err != nil {
		t.Fatalf("decode error body: %v", err)
	}
	return b.Error
}

func TestLoginFlow(t *testing.T) {
	e := newTestEnv(t)

	if rec := e.do(http.MethodGet, "/api/me", "", nil); rec.Code != http.StatusUnauthorized {
		t.Fatalf("me without cookie = %d", rec.Code)
	}
	rec := e.do(http.MethodPost, "/api/login", `{"password":"nope"}`, nil)
	if rec.Code != http.StatusUnauthorized || errorCode(t, rec) != "invalid_password" {
		t.Fatalf("wrong password = %d", rec.Code)
	}

	cookie := e.login(t)
	if rec := e.do(http.MethodGet, "/api/me", "", cookie); rec.Code != http.StatusNoContent {
		t.Fatalf("me with cookie = %d", rec.Code)
	}

	rec = e.do(http.MethodPost, "/api/logout", `{}`, cookie)
	if rec.Code != http.StatusNoContent || rec.Result().Cookies()[0].MaxAge >= 0 {
		t.Fatalf("logout = %d %+v", rec.Code, rec.Result().Cookies())
	}
}

func TestLoginBadRequestsAndRateLimit(t *testing.T) {
	e := newTestEnv(t)
	if rec := e.do(http.MethodPost, "/api/login", `{`, nil); rec.Code != http.StatusBadRequest {
		t.Fatalf("malformed = %d", rec.Code)
	}
	if rec := e.do(http.MethodPost, "/api/login", `{"password":""}`, nil); rec.Code != http.StatusBadRequest {
		t.Fatalf("empty = %d", rec.Code)
	}

	// Fresh env for the lockout test to avoid 400s counting against the limit
	e2 := newTestEnv(t)
	for i := 0; i < loginPerIPFailures-1; i++ {
		e2.do(http.MethodPost, "/api/login", `{"password":"nope"}`, nil)
	}
	// 5th wrong password should still return 401
	rec := e2.do(http.MethodPost, "/api/login", `{"password":"nope"}`, nil)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("5th wrong password = %d, want 401", rec.Code)
	}
	// 6th attempt should be rate limited
	rec = e2.do(http.MethodPost, "/api/login", `{"password":"correct horse"}`, nil)
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("after %d failures = %d, want 429 even with the right password", loginPerIPFailures, rec.Code)
	}
}

func TestLoginConcurrentArgon2Cap(t *testing.T) {
	// We need access to the underlying server to fill verifySlots. Create a fresh one.
	st, err := store.Open(filepath.Join(t.TempDir(), "cap.db"))
	if err != nil {
		t.Fatalf("store.Open() error = %v", err)
	}
	defer func() { _ = st.Close() }()

	srv2 := New(Options{
		Store:         st,
		PasswordHash:  hashForTests(t),
		SessionSecret: []byte(strings.Repeat("k", 32)),
		Now:           func() time.Time { return testNow },
		Web: fstest.MapFS{
			"index.html": {Data: []byte("<!doctype html><title>pawlet</title>")},
		},
	})

	// Fill both slots
	srv2.verifySlots <- struct{}{}
	srv2.verifySlots <- struct{}{}

	// Prove no password check ran: send WRONG password, get 429 not 401
	req := httptest.NewRequest(http.MethodPost, "/api/login", strings.NewReader(`{"password":"WRONG"}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Origin", "https://example.com")
	rec := httptest.NewRecorder()
	srv2.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("login with full verifySlots and wrong password = %d, want 429 not 401", rec.Code)
	}

	// Drain the slots
	<-srv2.verifySlots
	<-srv2.verifySlots

	// Now login should work
	rec = httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodPost, "/api/login", strings.NewReader(`{"password":"correct horse"}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Origin", "https://example.com")
	srv2.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("login after draining slots = %d, want 204", rec.Code)
	}
}

func TestLoginRequiresSameOrigin(t *testing.T) {
	e := newTestEnv(t)
	req := httptest.NewRequest(http.MethodPost, "/api/login", strings.NewReader(`{"password":"correct horse"}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Origin", "https://evil.test")
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("cross-origin login = %d", rec.Code)
	}
}

func TestHealth(t *testing.T) {
	e := newTestEnv(t)
	rec := e.do(http.MethodGet, "/healthz", "", nil)
	if rec.Code != http.StatusOK || rec.Body.String() != "ok" {
		t.Fatalf("healthz = %d %q", rec.Code, rec.Body.String())
	}
	_ = e.store.Close()
	if rec := e.do(http.MethodGet, "/healthz", "", nil); rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("healthz after close = %d", rec.Code)
	}
}

func TestUnknownAPIRouteIs404JSON(t *testing.T) {
	e := newTestEnv(t)
	rec := e.do(http.MethodGet, "/api/nope", "", e.login(t))
	if rec.Code != http.StatusNotFound || errorCode(t, rec) != "not_found" {
		t.Fatalf("unknown api = %d", rec.Code)
	}
	// POST to a defined route also hits the catch-all
	rec = e.do(http.MethodPost, "/api/me", `{}`, e.login(t))
	if rec.Code != http.StatusNotFound || errorCode(t, rec) != "not_found" {
		t.Fatalf("POST /api/me = %d, want 404 JSON not_found", rec.Code)
	}
}

func TestSPAServesAssetsAndFallsBackToIndex(t *testing.T) {
	e := newTestEnv(t)

	rec := e.do(http.MethodGet, "/assets/app.js", "", nil)
	if rec.Code != http.StatusOK || rec.Body.String() != "console.log(1)" ||
		!strings.Contains(rec.Header().Get("Cache-Control"), "immutable") {
		t.Fatalf("asset = %d %q %q", rec.Code, rec.Body.String(), rec.Header().Get("Cache-Control"))
	}
	// Missing asset under assets/ returns 404, not index.html
	rec = e.do(http.MethodGet, "/assets/missing.js", "", nil)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("missing asset = %d, want 404", rec.Code)
	}
	for _, p := range []string{"/", "/installs/abc", "/index.html"} {
		rec = e.do(http.MethodGet, p, "", nil)
		if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "<title>pawlet</title>") ||
			rec.Header().Get("Cache-Control") != "no-cache" {
			t.Fatalf("GET %s = %d %q", p, rec.Code, rec.Body.String())
		}
	}
	if rec.Header().Get("Content-Security-Policy") == "" {
		t.Fatal("SPA response missing security headers")
	}
}

func TestSPANotBuilt(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "x.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer func() { _ = st.Close() }()
	srv := New(Options{
		Store: st, PasswordHash: hashForTests(t), SessionSecret: []byte(strings.Repeat("k", 32)),
		Web: fstest.MapFS{},
	})
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("unbuilt SPA = %d", rec.Code)
	}
}
