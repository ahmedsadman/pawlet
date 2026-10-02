package attest

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"strconv"
	"time"
)

// Verification failures. Each is distinct so the caller can log precisely
// while still returning one opaque status to the client.
var (
	ErrPackageMismatch     = errors.New("attest: request package name mismatch")
	ErrRequestHashMismatch = errors.New("attest: request hash mismatch")
	ErrStaleToken          = errors.New("attest: token timestamp outside the accepted window")
	ErrAppNotRecognized    = errors.New("attest: app not recognized by Play")
	ErrCertMismatch        = errors.New("attest: signing certificate digest not allowed")
	ErrDeviceIntegrity     = errors.New("attest: device integrity not met")
)

// Policy is the set of values a verdict is checked against.
type Policy struct {
	PackageName string
	CertDigests []string
	MaxAge      time.Duration
}

// RequestHash binds an install ID to a challenge. The ":" delimiter is part of
// the contract: plain concatenation would let ("ab","cd") and ("abc","d")
// produce the same hash.
func RequestHash(installID, challenge string) string {
	sum := sha256.Sum256([]byte(installID + ":" + challenge))
	return hex.EncodeToString(sum[:])
}

// InstallHash is the stored identity for an install ID. Only the hash is
// persisted, so a database dump yields no usable identities.
func InstallHash(installID string) string {
	sum := sha256.Sum256([]byte(installID))
	return hex.EncodeToString(sum[:])
}

// Verify applies every verdict check. All-or-nothing: the first failure wins
// and nothing is partially trusted.
func Verify(p Payload, wantHash string, policy Policy, now time.Time) error {
	if p.RequestDetails.RequestPackageName != policy.PackageName {
		return ErrPackageMismatch
	}
	if subtle.ConstantTimeCompare([]byte(p.RequestDetails.RequestHash), []byte(wantHash)) != 1 {
		return ErrRequestHashMismatch
	}
	if err := checkFreshness(p.RequestDetails.TimestampMillis, policy.MaxAge, now); err != nil {
		return err
	}
	if p.AppIntegrity.AppRecognitionVerdict != "PLAY_RECOGNIZED" {
		return ErrAppNotRecognized
	}
	if !containsAny(p.AppIntegrity.CertificateSha256Digest, policy.CertDigests) {
		return ErrCertMismatch
	}
	if !contains(p.DeviceIntegrity.DeviceRecognitionVerdict, "MEETS_DEVICE_INTEGRITY") {
		return ErrDeviceIntegrity
	}
	return nil
}

func checkFreshness(raw string, maxAge time.Duration, now time.Time) error {
	ms, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return ErrStaleToken
	}
	delta := now.Sub(time.UnixMilli(ms))
	if delta < 0 {
		delta = -delta
	}
	if delta > maxAge {
		return ErrStaleToken
	}
	return nil
}

func contains(haystack []string, needle string) bool {
	for _, v := range haystack {
		if v == needle {
			return true
		}
	}
	return false
}

func containsAny(haystack, needles []string) bool {
	for _, n := range needles {
		if contains(haystack, n) {
			return true
		}
	}
	return false
}
