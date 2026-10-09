// Package admin serves the owner-only dashboard: password login, stats JSON
// computed from pawletd's database, ban/unban, and the embedded SPA.
package admin

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"

	"golang.org/x/crypto/argon2"
)

// argon2id parameters for new hashes. 64 MiB and two passes cost about a
// tenth of a second per login, which the login limiter keeps affordable.
const (
	argonTime      = 2
	argonMemoryKiB = 64 * 1024
	argonThreads   = 1
	argonKeyLen    = 32
	argonSaltLen   = 16
)

// ErrBadHash reports a password hash that is not a well-formed argon2id PHC
// string.
var ErrBadHash = errors.New("admin: malformed argon2id hash")

type phc struct {
	memory  uint32
	time    uint32
	threads uint8
	salt    []byte
	key     []byte
}

// HashPassword returns an argon2id PHC string for password with a fresh salt.
func HashPassword(password string) (string, error) {
	salt := make([]byte, argonSaltLen)
	if _, err := rand.Read(salt); err != nil {
		return "", fmt.Errorf("generate salt: %w", err)
	}
	key := argon2.IDKey([]byte(password), salt, argonTime, argonMemoryKiB, argonThreads, argonKeyLen)
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version, argonMemoryKiB, argonTime, argonThreads,
		base64.RawStdEncoding.EncodeToString(salt), base64.RawStdEncoding.EncodeToString(key)), nil
}

func parsePHC(encoded string) (phc, error) {
	parts := strings.Split(encoded, "$")
	if len(parts) != 6 || parts[0] != "" || parts[1] != "argon2id" {
		return phc{}, ErrBadHash
	}
	var version int
	if n, err := fmt.Sscanf(parts[2], "v=%d", &version); err != nil || n != 1 || version != argon2.Version {
		return phc{}, ErrBadHash
	}
	var p phc
	if n, err := fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &p.memory, &p.time, &p.threads); err != nil || n != 3 {
		return phc{}, ErrBadHash
	}
	if p.memory == 0 || p.time == 0 || p.threads == 0 {
		return phc{}, ErrBadHash
	}
	var err error
	if p.salt, err = base64.RawStdEncoding.DecodeString(parts[4]); err != nil || len(p.salt) == 0 {
		return phc{}, ErrBadHash
	}
	if p.key, err = base64.RawStdEncoding.DecodeString(parts[5]); err != nil || len(p.key) == 0 || len(p.key) > 64 {
		return phc{}, ErrBadHash
	}
	return p, nil
}

// VerifyPassword reports whether password matches encoded, comparing in
// constant time. A malformed hash is ErrBadHash.
func VerifyPassword(encoded, password string) (bool, error) {
	p, err := parsePHC(encoded)
	if err != nil {
		return false, err
	}
	got := argon2.IDKey([]byte(password), p.salt, p.time, p.memory, p.threads, uint32(len(p.key))) //nolint:gosec // key length capped at 64 above
	return subtle.ConstantTimeCompare(got, p.key) == 1, nil
}
