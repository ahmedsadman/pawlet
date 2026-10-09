package httpapi

import (
	"errors"

	"github.com/ahmedsadman/pawlet/server/internal/attest"
	"github.com/ahmedsadman/pawlet/server/internal/metrics"
)

// Counter records one occurrence of a metric key. Declared here because this
// package consumes it; *metrics.Recorder satisfies it.
type Counter interface {
	Inc(metric, key string)
}

// count is nil-safe so handlers built without metrics, as most tests do,
// still work.
func count(c Counter, metric, key string) {
	if c != nil {
		c.Inc(metric, key)
	}
}

// attestFailureKey names a verification failure for session_outcome.
func attestFailureKey(err error) string {
	switch {
	case errors.Is(err, attest.ErrPackageMismatch):
		return metrics.PackageMismatch
	case errors.Is(err, attest.ErrRequestHashMismatch):
		return metrics.RequestHashMismatch
	case errors.Is(err, attest.ErrStaleToken):
		return metrics.StaleToken
	case errors.Is(err, attest.ErrAppNotRecognized):
		return metrics.AppNotRecognized
	case errors.Is(err, attest.ErrCertMismatch):
		return metrics.CertMismatch
	case errors.Is(err, attest.ErrDeviceIntegrity):
		return metrics.DeviceIntegrity
	}
	return metrics.AttestFailed
}
