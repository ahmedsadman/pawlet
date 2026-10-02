package attest

import (
	"errors"
	"strconv"
	"testing"
	"time"
)

const (
	testPackage = "com.pastabyte.pawlet"
	testDigest  = "AbCd1234"
	testHash    = "deadbeef"
)

func testPolicy() Policy {
	return Policy{
		PackageName: testPackage,
		CertDigests: []string{testDigest},
		MaxAge:      5 * time.Minute,
	}
}

func validPayload(now time.Time) Payload {
	var p Payload
	p.RequestDetails.RequestPackageName = testPackage
	p.RequestDetails.RequestHash = testHash
	p.RequestDetails.TimestampMillis = millis(now)
	p.AppIntegrity.AppRecognitionVerdict = "PLAY_RECOGNIZED"
	p.AppIntegrity.PackageName = testPackage
	p.AppIntegrity.CertificateSha256Digest = []string{testDigest}
	p.DeviceIntegrity.DeviceRecognitionVerdict = []string{"MEETS_BASIC_INTEGRITY", "MEETS_DEVICE_INTEGRITY"}
	p.AccountDetails.AppLicensingVerdict = "LICENSED"
	return p
}

func millis(t time.Time) string {
	return strconv.FormatInt(t.UnixMilli(), 10)
}

func TestVerifyAcceptsAGenuineVerdict(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)

	if err := Verify(validPayload(now), testHash, testPolicy(), now); err != nil {
		t.Fatalf("Verify() error = %v, want nil", err)
	}
}

func TestVerifyRejectsWrongPackage(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	p := validPayload(now)
	p.RequestDetails.RequestPackageName = "com.evil.clone"

	err := Verify(p, testHash, testPolicy(), now)
	if !errors.Is(err, ErrPackageMismatch) {
		t.Fatalf("err = %v, want ErrPackageMismatch", err)
	}
}

func TestVerifyRejectsWrongRequestHash(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	p := validPayload(now)
	p.RequestDetails.RequestHash = "0000"

	err := Verify(p, testHash, testPolicy(), now)
	if !errors.Is(err, ErrRequestHashMismatch) {
		t.Fatalf("err = %v, want ErrRequestHashMismatch", err)
	}
}

func TestVerifyRejectsStaleToken(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	p := validPayload(now.Add(-10 * time.Minute))

	err := Verify(p, testHash, testPolicy(), now)
	if !errors.Is(err, ErrStaleToken) {
		t.Fatalf("err = %v, want ErrStaleToken", err)
	}
}

func TestVerifyRejectsFutureToken(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	p := validPayload(now.Add(10 * time.Minute))

	err := Verify(p, testHash, testPolicy(), now)
	if !errors.Is(err, ErrStaleToken) {
		t.Fatalf("err = %v, want ErrStaleToken", err)
	}
}

func TestVerifyRejectsUnrecognizedApp(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	p := validPayload(now)
	p.AppIntegrity.AppRecognitionVerdict = "UNRECOGNIZED_VERSION"

	err := Verify(p, testHash, testPolicy(), now)
	if !errors.Is(err, ErrAppNotRecognized) {
		t.Fatalf("err = %v, want ErrAppNotRecognized", err)
	}
}

func TestVerifyRejectsUnknownCertificate(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	p := validPayload(now)
	p.AppIntegrity.CertificateSha256Digest = []string{"someoneelse"}

	err := Verify(p, testHash, testPolicy(), now)
	if !errors.Is(err, ErrCertMismatch) {
		t.Fatalf("err = %v, want ErrCertMismatch", err)
	}
}

func TestVerifyRejectsFailedDeviceIntegrity(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	p := validPayload(now)
	p.DeviceIntegrity.DeviceRecognitionVerdict = []string{"MEETS_BASIC_INTEGRITY"}

	err := Verify(p, testHash, testPolicy(), now)
	if !errors.Is(err, ErrDeviceIntegrity) {
		t.Fatalf("err = %v, want ErrDeviceIntegrity", err)
	}
}

func TestVerifyRejectsEmptyDeviceVerdict(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	p := validPayload(now)
	p.DeviceIntegrity.DeviceRecognitionVerdict = nil

	err := Verify(p, testHash, testPolicy(), now)
	if !errors.Is(err, ErrDeviceIntegrity) {
		t.Fatalf("err = %v, want ErrDeviceIntegrity", err)
	}
}

func TestVerifyIgnoresLicensingVerdict(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	p := validPayload(now)
	p.AccountDetails.AppLicensingVerdict = "UNLICENSED"

	if err := Verify(p, testHash, testPolicy(), now); err != nil {
		t.Fatalf("Verify() error = %v, want nil (licensing is logged, not enforced)", err)
	}
}

func TestRequestHashIsStableAndDelimited(t *testing.T) {
	got := RequestHash("ab", "cd")
	again := RequestHash("ab", "cd")
	if got != again {
		t.Fatal("RequestHash is not deterministic")
	}
	// Without the delimiter, ("ab","cd") and ("abc","d") would collide.
	if got == RequestHash("abc", "d") {
		t.Fatal("RequestHash collides across differently split inputs")
	}
}
