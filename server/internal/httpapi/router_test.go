package httpapi

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ahmedsadman/pawlet/server/internal/store"
)

func TestHealthz(t *testing.T) {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)

	// Handlers struct with nil fields is fine; healthz doesn't call any handler.
	NewRouter(Handlers{}).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	if got := rec.Body.String(); got != "ok" {
		t.Fatalf("body = %q, want %q", got, "ok")
	}
}

// TestRouterRoutesEveryEndpoint verifies all declared routes are registered and
// reachable. Wrapping in Recovery converts panics (from nil handlers) to 500,
// proving the route exists without fully wiring the handlers for this test.
func TestRouterRoutesEveryEndpoint(t *testing.T) {
	routes := []struct {
		method string
		path   string
	}{
		{"GET", "/healthz"},
		{"GET", "/v1/challenge"},
		{"POST", "/v1/session"},
		{"POST", "/v1/classify"},
		{"GET", "/v1/prompt-bundle"},
	}

	// Bare handlers with no collaborators will panic. Recovery turns the panic
	// into 500, which proves the route is present (a missing route would 404).
	router := Chain(NewRouter(Handlers{}), Recovery(discardLogger()))

	for _, route := range routes {
		t.Run(route.method+" "+route.path, func(t *testing.T) {
			rec := httptest.NewRecorder()
			req := httptest.NewRequest(route.method, route.path, nil)
			router.ServeHTTP(rec, req)
			if rec.Code == http.StatusNotFound {
				t.Fatalf("route not found: %s %s", route.method, route.path)
			}
		})
	}
}

func TestRouterRejectsWrongMethod(t *testing.T) {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/classify", nil)

	NewRouter(Handlers{}).ServeHTTP(rec, req)

	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusMethodNotAllowed)
	}
}

type fakeHealth struct{ err error }

func (f fakeHealth) Ping(context.Context) error { return f.err }

func TestHealthzReportsDatabaseFailure(t *testing.T) {
	h := NewRouter(Handlers{
		Session:  &SessionHandler{Logger: discardLogger()},
		Classify: &ClassifyHandler{Logger: discardLogger()},
		Bundle:   NewBundleHandler([]string{"a/one:free"}),
		Health:   fakeHealth{err: errors.New("disk gone")},
		Logger:   discardLogger(),
	})
	rec := httptest.NewRecorder()

	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "database_unavailable") {
		t.Fatalf("body = %q, want the database_unavailable code", rec.Body.String())
	}
}

func TestHealthzPassesWhenDatabaseAnswers(t *testing.T) {
	h := NewRouter(Handlers{
		Session:  &SessionHandler{Logger: discardLogger()},
		Classify: &ClassifyHandler{Logger: discardLogger()},
		Bundle:   NewBundleHandler([]string{"a/one:free"}),
		Health:   fakeHealth{},
		Logger:   discardLogger(),
	})
	rec := httptest.NewRecorder()

	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))

	if rec.Code != http.StatusOK || rec.Body.String() != "ok" {
		t.Fatalf("status = %d body = %q, want 200 ok", rec.Code, rec.Body.String())
	}
}

func TestStorePingDetectsAClosedDatabase(t *testing.T) {
	s, err := store.Open(filepath.Join(t.TempDir(), "h.db"))
	if err != nil {
		t.Fatalf("Open() error = %v", err)
	}
	if err := s.Ping(context.Background()); err != nil {
		t.Fatalf("Ping() on a live store = %v, want nil", err)
	}

	_ = s.Close()

	if err := s.Ping(context.Background()); err == nil {
		t.Fatal("Ping() on a closed store = nil, want an error")
	}
}
