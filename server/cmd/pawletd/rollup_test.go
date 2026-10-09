package main

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/ahmedsadman/pawlet/server/internal/store"
)

// fakeRoller records the clock of each call and signals calls without ever
// blocking the loop under test.
type fakeRoller struct {
	mu    sync.Mutex
	times []time.Time
	err   error
	calls chan struct{} // buffered, size 1
}

func newFakeRoller(err error) *fakeRoller {
	return &fakeRoller{err: err, calls: make(chan struct{}, 1)}
}

func (f *fakeRoller) RollupModelStats(_ context.Context, now time.Time) (store.RollupResult, error) {
	f.mu.Lock()
	f.times = append(f.times, now)
	f.mu.Unlock()
	select {
	case f.calls <- struct{}{}:
	default:
	}
	if f.err != nil {
		return store.RollupResult{}, f.err
	}
	return store.RollupResult{Rows: 1, Messages: 5}, nil
}

func waitFor(t *testing.T, ch <-chan struct{}, what string) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(5 * time.Second):
		t.Fatalf("timed out waiting for %s", what)
	}
}

func discardLogger() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

func TestRollupRunsAtStartup(t *testing.T) {
	roller := newFakeRoller(nil)
	fixed := time.Date(2026, 10, 10, 3, 0, 0, 0, time.UTC)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		// An hour-long interval: any call inside the test is the startup run.
		runModelStatsRollup(ctx, roller, time.Hour, func() time.Time { return fixed }, discardLogger())
		close(done)
	}()

	waitFor(t, roller.calls, "the startup rollup")
	cancel()
	waitFor(t, done, "the loop to stop after cancel")

	roller.mu.Lock()
	defer roller.mu.Unlock()
	if len(roller.times) != 1 || !roller.times[0].Equal(fixed) {
		t.Fatalf("calls = %v, want exactly one at %v", roller.times, fixed)
	}
}

func TestRollupRetriesOnTheNextTickAfterAFailure(t *testing.T) {
	roller := newFakeRoller(errors.New("disk full"))
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		runModelStatsRollup(ctx, roller, 10*time.Millisecond, time.Now, discardLogger())
		close(done)
	}()

	waitFor(t, roller.calls, "the failing startup rollup")
	waitFor(t, roller.calls, "the retry on the next tick")
	cancel()
	waitFor(t, done, "the loop to stop after cancel")
}
