package admin

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func okHandler(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) }

func TestSecurityHeaders(t *testing.T) {
	rec := httptest.NewRecorder()
	securityHeaders(http.HandlerFunc(okHandler)).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	h := rec.Header()
	if !strings.Contains(h.Get("Content-Security-Policy"), "default-src 'self'") ||
		!strings.Contains(h.Get("Content-Security-Policy"), "frame-ancestors 'none'") ||
		h.Get("X-Content-Type-Options") != "nosniff" || h.Get("Referrer-Policy") != "no-referrer" {
		t.Fatalf("headers = %v", h)
	}
}

func TestSameOriginJSON(t *testing.T) {
	cases := []struct {
		name, contentType, origin string
		want                      int
	}{
		{"ok", "application/json", "http://example.com", http.StatusNoContent},
		{"ok with charset", "application/json; charset=utf-8", "https://example.com", http.StatusNoContent},
		{"form post", "application/x-www-form-urlencoded", "http://example.com", http.StatusForbidden},
		{"missing origin", "application/json", "", http.StatusForbidden},
		{"other origin", "application/json", "https://evil.test", http.StatusForbidden},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/api/login", strings.NewReader("{}"))
			req.Header.Set("Content-Type", c.contentType)
			if c.origin != "" {
				req.Header.Set("Origin", c.origin)
			}
			rec := httptest.NewRecorder()
			sameOriginJSON(okHandler)(rec, req)
			if rec.Code != c.want {
				t.Fatalf("status = %d, want %d", rec.Code, c.want)
			}
		})
	}
}
