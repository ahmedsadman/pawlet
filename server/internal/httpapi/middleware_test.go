package httpapi

import (
	"bytes"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func TestClientIPPrefersForwardedFromTrustedProxy(t *testing.T) {
	_, trusted, _ := net.ParseCIDR("172.16.0.0/12")
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.RemoteAddr = "172.18.0.5:51000"
	req.Header.Set("X-Forwarded-For", "203.0.113.9, 172.18.0.5")

	if got := clientIP(req, trusted); got != "203.0.113.9" {
		t.Fatalf("clientIP() = %q, want the forwarded address", got)
	}
}

func TestClientIPIgnoresForwardedFromUntrustedPeer(t *testing.T) {
	_, trusted, _ := net.ParseCIDR("172.16.0.0/12")
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.RemoteAddr = "198.51.100.7:51000"
	req.Header.Set("X-Forwarded-For", "203.0.113.9")

	if got := clientIP(req, trusted); got != "198.51.100.7" {
		t.Fatalf("clientIP() = %q, want the peer address", got)
	}
}

func TestClientIPWithNilTrustedProxyUsesPeer(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.RemoteAddr = "198.51.100.7:51000"
	req.Header.Set("X-Forwarded-For", "203.0.113.9")

	if got := clientIP(req, nil); got != "198.51.100.7" {
		t.Fatalf("clientIP() = %q, want the peer address", got)
	}
}

func TestRecoveryTurnsPanicInto500(t *testing.T) {
	h := Recovery(discardLogger())(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		panic("boom")
	}))
	rec := httptest.NewRecorder()

	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/v1/classify", nil))

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", rec.Code)
	}
}

func TestRequestLoggerNeverLogsTheBody(t *testing.T) {
	var buf bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&buf, nil))
	h := RequestLogger(logger)(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	body := strings.NewReader(`{"content":"SECRET-SMS-TEXT"}`)
	rec := httptest.NewRecorder()

	h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/v1/classify", body))

	if strings.Contains(buf.String(), "SECRET-SMS-TEXT") {
		t.Fatalf("log contains the request body: %s", buf.String())
	}
	if !strings.Contains(buf.String(), "/v1/classify") {
		t.Fatalf("log is missing the path: %s", buf.String())
	}
}

func TestRequestLoggerRecordsTheStatus(t *testing.T) {
	var buf bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&buf, nil))
	h := RequestLogger(logger)(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusTeapot)
	}))

	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/x", nil))

	if !strings.Contains(buf.String(), "418") {
		t.Fatalf("log is missing the status: %s", buf.String())
	}
}

func TestRequestLoggerDefaults200WhenNoWriteHeader(t *testing.T) {
	var buf bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&buf, nil))
	h := RequestLogger(logger)(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok"))
	}))

	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/x", nil))

	if !strings.Contains(buf.String(), "200") {
		t.Fatalf("log is missing the implicit 200 status: %s", buf.String())
	}
}

func TestClientIPHandlesRemoteAddrWithoutPort(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.RemoteAddr = "198.51.100.7"

	if got := clientIP(req, nil); got != "198.51.100.7" {
		t.Fatalf("clientIP() = %q, want the peer address", got)
	}
}

func TestChainAppliesOutermostFirst(t *testing.T) {
	var order []string
	mw := func(name string) Middleware {
		return func(next http.Handler) http.Handler {
			return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				order = append(order, name)
				next.ServeHTTP(w, r)
			})
		}
	}
	h := Chain(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		order = append(order, "handler")
	}), mw("first"), mw("second"))

	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/", nil))

	if strings.Join(order, ",") != "first,second,handler" {
		t.Fatalf("order = %v, want first,second,handler", order)
	}
}

func TestClientIPIgnoresClientSuppliedForwardedPrefix(t *testing.T) {
	_, trusted, _ := net.ParseCIDR("172.16.0.0/12")
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.RemoteAddr = "172.18.0.5:51000"
	// The client forged the first entry; Caddy appended the real peer.
	req.Header.Set("X-Forwarded-For", "1.2.3.4, 203.0.113.9")

	if got := clientIP(req, trusted); got != "203.0.113.9" {
		t.Fatalf("clientIP() = %q, want the rightmost untrusted hop", got)
	}
}

func TestClientIPFallsBackWhenEveryHopIsTrusted(t *testing.T) {
	_, trusted, _ := net.ParseCIDR("172.16.0.0/12")
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.RemoteAddr = "172.18.0.5:51000"
	req.Header.Set("X-Forwarded-For", "172.18.0.9, 172.18.0.5")

	if got := clientIP(req, trusted); got != "172.18.0.5" {
		t.Fatalf("clientIP() = %q, want the peer", got)
	}
}
