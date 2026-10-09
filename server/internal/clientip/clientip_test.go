package clientip

import (
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestFromPrefersForwardedFromTrustedProxy(t *testing.T) {
	_, trusted, _ := net.ParseCIDR("172.16.0.0/12")
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.RemoteAddr = "172.18.0.5:51000"
	req.Header.Set("X-Forwarded-For", "203.0.113.9, 172.18.0.5")

	if got := From(req, trusted); got != "203.0.113.9" {
		t.Fatalf("From() = %q, want the forwarded address", got)
	}
}

func TestFromIgnoresForwardedFromUntrustedPeer(t *testing.T) {
	_, trusted, _ := net.ParseCIDR("172.16.0.0/12")
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.RemoteAddr = "198.51.100.7:51000"
	req.Header.Set("X-Forwarded-For", "203.0.113.9")

	if got := From(req, trusted); got != "198.51.100.7" {
		t.Fatalf("From() = %q, want the peer address", got)
	}
}

func TestFromWithNilTrustedProxyUsesPeer(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.RemoteAddr = "198.51.100.7:51000"
	req.Header.Set("X-Forwarded-For", "203.0.113.9")

	if got := From(req, nil); got != "198.51.100.7" {
		t.Fatalf("From() = %q, want the peer address", got)
	}
}

func TestFromHandlesRemoteAddrWithoutPort(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.RemoteAddr = "198.51.100.7"

	if got := From(req, nil); got != "198.51.100.7" {
		t.Fatalf("From() = %q, want the peer address", got)
	}
}

func TestFromIgnoresClientSuppliedForwardedPrefix(t *testing.T) {
	_, trusted, _ := net.ParseCIDR("172.16.0.0/12")
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.RemoteAddr = "172.18.0.5:51000"
	// The client forged the first entry; Caddy appended the real peer.
	req.Header.Set("X-Forwarded-For", "1.2.3.4, 203.0.113.9")

	if got := From(req, trusted); got != "203.0.113.9" {
		t.Fatalf("From() = %q, want the rightmost untrusted hop", got)
	}
}

func TestFromFallsBackWhenEveryHopIsTrusted(t *testing.T) {
	_, trusted, _ := net.ParseCIDR("172.16.0.0/12")
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.RemoteAddr = "172.18.0.5:51000"
	req.Header.Set("X-Forwarded-For", "172.18.0.9, 172.18.0.5")

	if got := From(req, trusted); got != "172.18.0.5" {
		t.Fatalf("From() = %q, want the peer", got)
	}
}
