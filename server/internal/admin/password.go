// Package admin serves the owner-only dashboard: password login, stats JSON
// computed from pawletd's database, ban/unban, and the embedded SPA.
package admin

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"strconv"
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

	if parts[2] != "v=19" {
		return phc{}, ErrBadHash
	}

	params := strings.Split(parts[3], ",")
	if len(params) != 3 {
		return phc{}, ErrBadHash
	}

	var p phc
	if !strings.HasPrefix(params[0], "m=") {
		return phc{}, ErrBadHash
	}
	mem, err := strconv.ParseUint(params[0][2:], 10, 32)
	if err != nil || mem < 19456 || mem > 1048576 {
		return phc{}, ErrBadHash
	}
	p.memory = uint32(mem)

	if !strings.HasPrefix(params[1], "t=") {
		return phc{}, ErrBadHash
	}
	tm, err := strconv.ParseUint(params[1][2:], 10, 32)
	if err != nil || tm < 1 || tm > 10 {
		return phc{}, ErrBadHash
	}
	p.time = uint32(tm)

	if !strings.HasPrefix(params[2], "p=") {
		return phc{}, ErrBadHash
	}
	thr, err := strconv.ParseUint(params[2][2:], 10, 8)
	if err != nil || thr < 1 || thr > 16 {
		return phc{}, ErrBadHash
	}
	p.threads = uint8(thr)

	if p.salt, err = base64.RawStdEncoding.DecodeString(parts[4]); err != nil || len(p.salt) < 8 {
		return phc{}, ErrBadHash
	}

	if p.key, err = base64.RawStdEncoding.DecodeString(parts[5]); err != nil || len(p.key) < 16 || len(p.key) > 64 {
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
