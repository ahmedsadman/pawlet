// Package clientip resolves the caller's address behind a trusted reverse proxy.
package clientip

import (
	"net"
	"net/http"
	"strings"
)

// From extracts the client IP from the request, honoring X-Forwarded-For
// only when the immediate peer is within the trusted proxy CIDR.
func From(r *http.Request, trusted *net.IPNet) string {
	// net.SplitHostPort, not a naive cut on ":" — an IPv6 peer arrives as
	// "[::1]:54321" and cutting on the first colon yields "[", collapsing
	// every IPv6 client into one shared rate-limit bucket.
	peerHost, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		peerHost = r.RemoteAddr
	}

	if trusted == nil {
		return peerHost
	}

	peerIP := net.ParseIP(peerHost)
	if peerIP == nil || !trusted.Contains(peerIP) {
		return peerHost
	}

	forwarded := r.Header.Get("X-Forwarded-For")
	if forwarded == "" {
		return peerHost
	}

	// Walk right to left. Each proxy appends the address it received from, so
	// the rightmost entries are the ones our own infrastructure wrote and the
	// first untrusted entry from the right is the real client. Reading the
	// leftmost entry instead would return whatever the client put there, which
	// is attacker-controlled and would defeat per-IP rate limiting.
	hops := strings.Split(forwarded, ",")
	for i := len(hops) - 1; i >= 0; i-- {
		hop := strings.TrimSpace(hops[i])
		ip := net.ParseIP(hop)
		if ip == nil {
			continue
		}
		if !trusted.Contains(ip) {
			return hop
		}
	}
	return peerHost
}
