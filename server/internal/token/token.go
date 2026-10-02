// Package token mints and verifies the short-lived session JWT.
package token

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// Issuer signs and validates session tokens. Tokens are not stored: revocation
// runs through the install's banned flag, checked on every classify.
type Issuer struct {
	secret []byte
	ttl    time.Duration
}

// String redacts the signing secret so an Issuer logged with %v or %+v cannot
// leak it.
func (i *Issuer) String() string { return "token.Issuer{redacted}" }

// New builds an Issuer.
func New(secret []byte, ttl time.Duration) *Issuer {
	return &Issuer{secret: secret, ttl: ttl}
}

// TTL is the lifetime every minted token gets, so callers can report an expiry
// without restating the constant.
func (i *Issuer) TTL() time.Duration { return i.ttl }

// Mint returns a signed token whose subject is the install hash.
func (i *Issuer) Mint(installHash string, now time.Time) (string, error) {
	jti, err := randomHex(16)
	if err != nil {
		return "", err
	}
	claims := jwt.RegisteredClaims{
		Subject:   installHash,
		ID:        jti,
		IssuedAt:  jwt.NewNumericDate(now),
		ExpiresAt: jwt.NewNumericDate(now.Add(i.ttl)),
	}
	signed, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(i.secret)
	if err != nil {
		return "", fmt.Errorf("sign session token: %w", err)
	}
	return signed, nil
}

// Verify checks the signature and expiry, returning the install hash.
//
// Every error it returns must be mapped to a bare 401 by the caller: the
// wrapped library text names the signing algorithm and failure mode, which is
// detail no client should see.
func (i *Issuer) Verify(signed string, now time.Time) (string, error) {
	claims := &jwt.RegisteredClaims{}
	// Two alg defences on purpose. The keyfunc assertion is the primary one;
	// WithValidMethods below also pins HS256 so a token signed HS384 with the
	// same secret is refused even if the assertion is ever loosened.
	_, err := jwt.ParseWithClaims(signed, claims, func(t *jwt.Token) (any, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing method %v", t.Header["alg"])
		}
		return i.secret, nil
	},
		jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()}),
		jwt.WithTimeFunc(func() time.Time { return now }),
	)
	if err != nil {
		return "", fmt.Errorf("verify session token: %w", err)
	}
	if claims.Subject == "" {
		return "", fmt.Errorf("verify session token: empty subject")
	}
	return claims.Subject, nil
}

func randomHex(n int) (string, error) {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("generate token id: %w", err)
	}
	return hex.EncodeToString(buf), nil
}
