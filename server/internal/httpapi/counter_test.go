package httpapi

import (
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"

	"github.com/ahmedsadman/pawlet/server/internal/attest"
	"github.com/ahmedsadman/pawlet/server/internal/metrics"
)

// fakeCounter records Inc calls for assertions.
type fakeCounter struct {
	mu  sync.Mutex
	got map[string]int
}

func newFakeCounter() *fakeCounter { return &fakeCounter{got: make(map[string]int)} }

func (f *fakeCounter) Inc(metric, key string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.got[metric+"/"+key]++
}

// n returns how many times metric/key was counted.
func (f *fakeCounter) n(metric, key string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.got[metric+"/"+key]
}

// total returns how many times any key of metric was counted.
func (f *fakeCounter) total(metric string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	sum := 0
	for k, v := range f.got {
		if strings.HasPrefix(k, metric+"/") {
			sum += v
		}
	}
	return sum
}

func TestAttestFailureKey(t *testing.T) {
	cases := []struct {
		err  error
		want string
	}{
		{attest.ErrPackageMismatch, metrics.PackageMismatch},
		{attest.ErrRequestHashMismatch, metrics.RequestHashMismatch},
		{attest.ErrStaleToken, metrics.StaleToken},
		{attest.ErrAppNotRecognized, metrics.AppNotRecognized},
		{attest.ErrCertMismatch, metrics.CertMismatch},
		{attest.ErrDeviceIntegrity, metrics.DeviceIntegrity},
		{fmt.Errorf("wrapped: %w", attest.ErrCertMismatch), metrics.CertMismatch},
		{errors.New("something new"), metrics.AttestFailed},
	}
	for _, c := range cases {
		if got := attestFailureKey(c.err); got != c.want {
			t.Errorf("attestFailureKey(%v) = %q, want %q", c.err, got, c.want)
		}
	}
}

func TestCountIsNilSafe(_ *testing.T) {
	count(nil, metrics.SessionOutcome, metrics.OK) // must not panic
}
