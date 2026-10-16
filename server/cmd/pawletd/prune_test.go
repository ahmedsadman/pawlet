package main

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

// fakePruner records the clock of each call and signals calls without ever
// blocking the loop under test.
type fakePruner struct {
	mu    sync.Mutex
	times []time.Time
	err   error
	calls chan struct{} // buffered, size 1
}

func newFakePruner(err error) *fakePruner {
	return &fakePruner{err: err, calls: make(chan struct{}, 1)}
}

func (f *fakePruner) PruneLLMMessages(_ context.Context, now time.Time) (int64, error) {
	f.mu.Lock()
	f.times = append(f.times, now)
	f.mu.Unlock()
	select {
	case f.calls <- struct{}{}:
	default:
	}
	return 1, f.err
}

func TestPruneRunsAtStartup(t *testing.T) {
	pruner := newFakePruner(nil)
	fixed := time.Date(2026, 10, 16, 3, 0, 0, 0, time.UTC)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		// An hour-long interval: any call inside the test is the startup run.
		runLLMMessagePrune(ctx, pruner, time.Hour, func() time.Time { return fixed }, discardLogger())
		close(done)
	}()

	waitFor(t, pruner.calls, "the startup prune")
	cancel()
	waitFor(t, done, "the loop to stop after cancel")

	pruner.mu.Lock()
	defer pruner.mu.Unlock()
	if len(pruner.times) != 1 || !pruner.times[0].Equal(fixed) {
		t.Fatalf("calls = %v, want exactly one at %v", pruner.times, fixed)
	}
}

func TestPruneRetriesOnTheNextTickAfterAFailure(t *testing.T) {
	pruner := newFakePruner(errors.New("disk full"))
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		runLLMMessagePrune(ctx, pruner, 10*time.Millisecond, time.Now, discardLogger())
		close(done)
	}()

	waitFor(t, pruner.calls, "the failing startup prune")
	waitFor(t, pruner.calls, "the retry on the next tick")
	cancel()
	waitFor(t, done, "the loop to stop after cancel")
}
