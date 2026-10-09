package admin

import (
	"net/http"
	"net/url"
	"strings"
)

// contentSecurityPolicy allows only same-origin resources. Inline styles are
// allowed because the chart library sets style attributes; scripts are not.
const contentSecurityPolicy = "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; " +
	"base-uri 'none'; form-action 'self'; frame-ancestors 'none'"

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy", contentSecurityPolicy)
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("X-Frame-Options", "DENY")
		next.ServeHTTP(w, r)
	})
}

// sameOriginJSON guards every state-changing request. SameSite=Strict
// already keeps the cookie off cross-site requests; requiring a JSON body and
// an Origin matching the host closes what remains (plain form posts, older
// browsers, sibling subdomains).
func sameOriginJSON(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") {
			writeError(w, http.StatusForbidden, "forbidden")
			return
		}
		origin := r.Header.Get("Origin")
		u, err := url.Parse(origin)
		if origin == "" || err != nil || u.Host != r.Host {
			writeError(w, http.StatusForbidden, "forbidden")
			return
		}
		next(w, r)
	}
}
