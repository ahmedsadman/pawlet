package admin

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestSessionsRoundTrip(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	s := newSessions([]byte(strings.Repeat("k", 32)), func() time.Time { return now })

	rec := httptest.NewRecorder()
	if err := s.start(rec); err != nil {
		t.Fatalf("start() error = %v", err)
	}
	cookies := rec.Result().Cookies()
	if len(cookies) != 1 {
		t.Fatalf("cookies = %v", cookies)
	}
	c := cookies[0]
	if c.Name != cookieName || !c.HttpOnly || !c.Secure || c.SameSite != http.SameSiteStrictMode || c.Path != "/" {
		t.Fatalf("cookie flags = %+v", c)
	}

	req := httptest.NewRequest(http.MethodGet, "/api/me", nil)
	req.AddCookie(c)
	if !s.valid(req) {
		t.Fatal("fresh session invalid")
	}

	now = now.Add(sessionTTL + time.Second)
	if s.valid(req) {
		t.Fatal("expired session valid")
	}
}

func TestSessionsRejectForeignTokens(t *testing.T) {
	now := func() time.Time { return time.Unix(1_700_000_000, 0) }
	ours := newSessions([]byte(strings.Repeat("k", 32)), now)
	theirs := newSessions([]byte(strings.Repeat("x", 32)), now)

	rec := httptest.NewRecorder()
	_ = theirs.start(rec)
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.AddCookie(rec.Result().Cookies()[0])
	if ours.valid(req) {
		t.Fatal("token signed with another secret accepted")
	}
	if ours.valid(httptest.NewRequest(http.MethodGet, "/", nil)) {
		t.Fatal("request without cookie accepted")
	}
}

func TestSessionsEndClearsCookie(t *testing.T) {
	s := newSessions([]byte(strings.Repeat("k", 32)), time.Now)
	rec := httptest.NewRecorder()
	s.end(rec)
	c := rec.Result().Cookies()[0]
	if c.Name != cookieName || c.MaxAge >= 0 {
		t.Fatalf("cleared cookie = %+v", c)
	}
}
