package admin

import (
	"mime"
	"net/http"
	"net/url"
)

// contentSecurityPolicy allows only same-origin resources. Inline styles are
// allowed because the chart library sets style attributes; scripts are not.
const contentSecurityPolicy = "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; " +
	"object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy", contentSecurityPolicy)
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Cross-Origin-Opener-Policy", "same-origin")
		h.Set("Strict-Transport-Security", "max-age=31536000")
		next.ServeHTTP(w, r)
	})
}

// sameOriginJSON guards every state-changing request. SameSite=Strict
// already keeps the cookie off cross-site requests; requiring a JSON body and
// an Origin matching the host closes what remains (plain form posts, older
// browsers, sibling subdomains).
func sameOriginJSON(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// Parse and check Content-Type
		mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
		if err != nil || mediaType != "application/json" {
			writeError(w, http.StatusForbidden, "forbidden")
			return
		}

		// Require non-empty Host
		if r.Host == "" {
			writeError(w, http.StatusForbidden, "forbidden")
			return
		}

		// Parse Origin
		originStr := r.Header.Get("Origin")
		if originStr == "" || originStr == "null" {
			writeError(w, http.StatusForbidden, "forbidden")
			return
		}
		origin, err := url.Parse(originStr)
		if err != nil {
			writeError(w, http.StatusForbidden, "forbidden")
			return
		}

		// Check Origin host matches request Host
		if origin.Host != r.Host {
			writeError(w, http.StatusForbidden, "forbidden")
			return
		}

		// Require https, or http only for loopback hosts
		switch origin.Scheme {
		case "https":
			// Always OK
		case "http":
			hostname := origin.Hostname()
			if hostname != "localhost" && hostname != "127.0.0.1" && hostname != "::1" {
				writeError(w, http.StatusForbidden, "forbidden")
				return
			}
		default:
			writeError(w, http.StatusForbidden, "forbidden")
			return
		}

		next(w, r)
	}
}
