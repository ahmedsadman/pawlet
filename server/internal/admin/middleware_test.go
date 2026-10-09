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
	csp := h.Get("Content-Security-Policy")
	if !strings.Contains(csp, "default-src 'self'") ||
		!strings.Contains(csp, "frame-ancestors 'none'") ||
		!strings.Contains(csp, "object-src 'none'") ||
		h.Get("X-Content-Type-Options") != "nosniff" ||
		h.Get("Referrer-Policy") != "no-referrer" ||
		h.Get("X-Frame-Options") != "DENY" ||
		h.Get("Cross-Origin-Opener-Policy") != "same-origin" ||
		h.Get("Strict-Transport-Security") != "max-age=31536000" {
		t.Fatalf("headers = %v", h)
	}
}

func TestSameOriginJSON(t *testing.T) {
	cases := []struct {
		name, contentType, origin, host string
		want                            int
	}{
		{"ok https", "application/json", "https://example.com", "example.com", http.StatusNoContent},
		{"ok with charset", "application/json; charset=utf-8", "https://example.com", "example.com", http.StatusNoContent},
		{"ok localhost http", "application/json", "http://localhost:5173", "localhost:5173", http.StatusNoContent},
		{"ok 127.0.0.1 http", "application/json", "http://127.0.0.1:3000", "127.0.0.1:3000", http.StatusNoContent},
		{"ok ::1 http", "application/json", "http://[::1]:8080", "[::1]:8080", http.StatusNoContent},
		{"form post", "application/x-www-form-urlencoded", "https://example.com", "example.com", http.StatusForbidden},
		{"missing origin", "application/json", "", "example.com", http.StatusForbidden},
		{"other origin", "application/json", "https://evil.test", "example.com", http.StatusForbidden},
		{"origin null", "application/json", "null", "example.com", http.StatusForbidden},
		{"port mismatch", "application/json", "https://example.com:8443", "example.com", http.StatusForbidden},
		{"http non-loopback", "application/json", "http://example.com", "example.com", http.StatusForbidden},
		{"wrong media type", "application/jsonx", "https://example.com", "example.com", http.StatusForbidden},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/api/login", strings.NewReader("{}"))
			req.Host = c.host
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
