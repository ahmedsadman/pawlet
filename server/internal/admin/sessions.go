package admin

import (
	"net/http"
	"time"

	"github.com/ahmedsadman/pawlet/server/internal/token"
)

const (
	cookieName   = "__Host-pawlet_admin"
	sessionTTL   = 7 * 24 * time.Hour
	adminSubject = "admin"
)

// sessions issues and checks the admin cookie: a JWT signed with the admin's
// own secret, so it can never be confused with a pawletd session token.
type sessions struct {
	issuer *token.Issuer
	now    func() time.Time
}

func newSessions(secret []byte, now func() time.Time) *sessions {
	return &sessions{issuer: token.New(secret, sessionTTL), now: now}
}

func (s *sessions) cookie(value string, maxAge int) *http.Cookie {
	return &http.Cookie{
		Name:     cookieName,
		Value:    value,
		Path:     "/",
		MaxAge:   maxAge,
		HttpOnly: true,
		Secure:   true,
		SameSite: http.SameSiteStrictMode,
	}
}

func (s *sessions) start(w http.ResponseWriter) error {
	tok, err := s.issuer.Mint(adminSubject, s.now())
	if err != nil {
		return err
	}
	http.SetCookie(w, s.cookie(tok, int(sessionTTL.Seconds())))
	return nil
}

func (s *sessions) end(w http.ResponseWriter) {
	http.SetCookie(w, s.cookie("", -1))
}

func (s *sessions) valid(r *http.Request) bool {
	c, err := r.Cookie(cookieName)
	if err != nil {
		return false
	}
	sub, err := s.issuer.Verify(c.Value, s.now())
	return err == nil && sub == adminSubject
}
