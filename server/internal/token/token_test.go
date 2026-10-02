package token

import (
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

var secret = []byte("0123456789abcdef0123456789abcdef")

func TestMintThenVerifyRoundTrips(t *testing.T) {
	issuer := New(secret, 24*time.Hour)
	now := time.Unix(1_700_000_000, 0)

	signed, err := issuer.Mint("install-hash", now)
	if err != nil {
		t.Fatalf("Mint() error = %v", err)
	}

	gotHash, err := issuer.Verify(signed, now.Add(time.Hour))
	if err != nil {
		t.Fatalf("Verify() error = %v", err)
	}
	if gotHash != "install-hash" {
		t.Fatalf("subject = %q, want install-hash", gotHash)
	}
}

func TestVerifyRejectsExpired(t *testing.T) {
	issuer := New(secret, time.Hour)
	now := time.Unix(1_700_000_000, 0)
	signed, _ := issuer.Mint("install-hash", now)

	if _, err := issuer.Verify(signed, now.Add(2*time.Hour)); err == nil {
		t.Fatal("Verify() error = nil, want an expiry failure")
	}
}

func TestVerifyRejectsWrongSecret(t *testing.T) {
	signed, _ := New(secret, time.Hour).Mint("install-hash", time.Unix(1_700_000_000, 0))
	other := New([]byte("ffffffffffffffffffffffffffffffff"), time.Hour)

	if _, err := other.Verify(signed, time.Unix(1_700_000_000, 0)); err == nil {
		t.Fatal("Verify() error = nil, want a signature failure")
	}
}

func TestVerifyRejectsGarbage(t *testing.T) {
	if _, err := New(secret, time.Hour).Verify("not-a-jwt", time.Unix(1_700_000_000, 0)); err == nil {
		t.Fatal("Verify() error = nil, want a parse failure")
	}
}

func TestMintProducesDistinctJTIs(t *testing.T) {
	issuer := New(secret, time.Hour)
	now := time.Unix(1_700_000_000, 0)

	a, _ := issuer.Mint("install-hash", now)
	b, _ := issuer.Mint("install-hash", now)

	if a == b {
		t.Fatal("two mints produced an identical token")
	}
}

func TestTTLIsReported(t *testing.T) {
	if got := New(secret, 24*time.Hour).TTL(); got != 24*time.Hour {
		t.Fatalf("TTL() = %v, want 24h", got)
	}
}

func TestVerifyRejectsAlgNone(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	claims := jwt.RegisteredClaims{
		Subject:   "install-hash",
		ID:        "fake-jti",
		IssuedAt:  jwt.NewNumericDate(now),
		ExpiresAt: jwt.NewNumericDate(now.Add(time.Hour)),
	}
	forged, _ := jwt.NewWithClaims(jwt.SigningMethodNone, claims).SignedString(jwt.UnsafeAllowNoneSignatureType)

	issuer := New(secret, time.Hour)
	if _, err := issuer.Verify(forged, now); err == nil {
		t.Fatal("Verify() error = nil, want rejection of alg:none")
	}
}
