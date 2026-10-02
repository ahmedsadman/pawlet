package attest

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestGoogleDecoderParsesPayload(t *testing.T) {
	var gotBody string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		gotBody = string(raw)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"tokenPayloadExternal":{
			"requestDetails":{"requestPackageName":"com.pastabyte.pawlet","requestHash":"abc","timestampMillis":"1700000000000"},
			"appIntegrity":{"appRecognitionVerdict":"PLAY_RECOGNIZED","certificateSha256Digest":["dig"]},
			"deviceIntegrity":{"deviceRecognitionVerdict":["MEETS_DEVICE_INTEGRITY"]},
			"accountDetails":{"appLicensingVerdict":"LICENSED"}}}`))
	}))
	t.Cleanup(srv.Close)

	d := &GoogleDecoder{Client: srv.Client(), Endpoint: srv.URL}

	got, err := d.Decode(context.Background(), "integrity-token-value")
	if err != nil {
		t.Fatalf("Decode() error = %v", err)
	}
	if got.AppIntegrity.AppRecognitionVerdict != "PLAY_RECOGNIZED" {
		t.Errorf("verdict = %q", got.AppIntegrity.AppRecognitionVerdict)
	}
	if got.RequestDetails.RequestHash != "abc" {
		t.Errorf("requestHash = %q", got.RequestDetails.RequestHash)
	}
	if !strings.Contains(gotBody, "integrity-token-value") {
		t.Errorf("request body = %q, want it to carry the token", gotBody)
	}
}

func TestGoogleDecoderReportsNon200(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"error":"denied"}`))
	}))
	t.Cleanup(srv.Close)

	d := &GoogleDecoder{Client: srv.Client(), Endpoint: srv.URL}

	if _, err := d.Decode(context.Background(), "tok"); err == nil {
		t.Fatal("Decode() error = nil, want an error for HTTP 403")
	}
}

func TestGoogleDecoderReportsMalformedJSON(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{not json`))
	}))
	t.Cleanup(srv.Close)

	d := &GoogleDecoder{Client: srv.Client(), Endpoint: srv.URL}

	if _, err := d.Decode(context.Background(), "tok"); err == nil {
		t.Fatal("Decode() error = nil, want an error for a malformed body")
	}
}

func TestGoogleDecoderHonoursContextCancellation(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"tokenPayloadExternal":{}}`))
	}))
	t.Cleanup(srv.Close)

	d := &GoogleDecoder{Client: srv.Client(), Endpoint: srv.URL}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	if _, err := d.Decode(ctx, "tok"); err == nil {
		t.Fatal("Decode() error = nil, want a context cancellation error")
	}
}

func TestGoogleDecoderDistinguishesUnreachableFromRejected(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
	}))
	t.Cleanup(srv.Close)

	rejected := &GoogleDecoder{Client: srv.Client(), Endpoint: srv.URL}
	if _, err := rejected.Decode(context.Background(), "tok"); !errors.Is(err, ErrDecodeRejected) {
		t.Fatalf("err = %v, want ErrDecodeRejected", err)
	}

	srv.Close()
	unreachable := &GoogleDecoder{Client: srv.Client(), Endpoint: srv.URL}
	if _, err := unreachable.Decode(context.Background(), "tok"); !errors.Is(err, ErrDecodeUnreachable) {
		t.Fatalf("err = %v, want ErrDecodeUnreachable", err)
	}
}
