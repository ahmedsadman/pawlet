package quota

import (
	"bytes"
	"context"
	"log/slog"
	"sync"
	"testing"
	"time"
)

type fakeSink struct {
	calls    int64
	usage    map[string]map[string]int64 // day -> idHash -> calls
	loadErr  error
	flushErr error
}

func (f *fakeSink) PersistUsage(_ context.Context, deltas []Delta) error {
	if f.flushErr != nil {
		return f.flushErr
	}
	for _, d := range deltas {
		f.calls += d.Calls
		if f.usage == nil {
			f.usage = make(map[string]map[string]int64)
		}
		if f.usage[d.Day] == nil {
			f.usage[d.Day] = make(map[string]int64)
		}
		f.usage[d.Day][d.IDHash] += d.Calls
	}
	return nil
}

func (f *fakeSink) LoadUsage(_ context.Context, day string) (map[string]int64, error) {
	if f.loadErr != nil {
		return nil, f.loadErr
	}
	if f.usage == nil || f.usage[day] == nil {
		return make(map[string]int64), nil
	}
	return f.usage[day], nil
}

func newClock(start time.Time) (func() time.Time, func(time.Duration)) {
	now := start
	return func() time.Time { return now }, func(d time.Duration) { now = now.Add(d) }
}

func TestAllowsUntilDailyLimit(t *testing.T) {
	clock, _ := newClock(time.Unix(1_700_000_000, 0).UTC())
	l := New(Limits{Daily: 2, Burst: 100, GlobalDaily: 1000}, &fakeSink{}, clock)

	for i := 0; i < 2; i++ {
		if d := l.Admit("install-a"); !d.Allowed {
			t.Fatalf("call %d denied: %+v", i, d)
		}
	}
	d := l.Admit("install-a")
	if d.Allowed {
		t.Fatal("third call allowed, want denied")
	}
	if d.Reason != ReasonDaily {
		t.Fatalf("Reason = %v, want ReasonDaily", d.Reason)
	}
}

func TestBurstLimitIsPerMinute(t *testing.T) {
	clock, advance := newClock(time.Unix(1_700_000_000, 0).UTC())
	l := New(Limits{Daily: 100, Burst: 1, GlobalDaily: 1000}, &fakeSink{}, clock)

	if d := l.Admit("install-a"); !d.Allowed {
		t.Fatal("first call denied")
	}
	d := l.Admit("install-a")
	if d.Allowed || d.Reason != ReasonBurst {
		t.Fatalf("second call = %+v, want denied with ReasonBurst", d)
	}
	if d.RetryAfter <= 0 || d.RetryAfter > time.Minute {
		t.Fatalf("RetryAfter = %v, want within a minute", d.RetryAfter)
	}

	advance(time.Minute)
	if d := l.Admit("install-a"); !d.Allowed {
		t.Fatalf("call after the window denied: %+v", d)
	}
}

func TestDailyCounterResetsOnNewDay(t *testing.T) {
	clock, advance := newClock(time.Date(2026, 10, 2, 23, 0, 0, 0, time.UTC))
	l := New(Limits{Daily: 1, Burst: 100, GlobalDaily: 1000}, &fakeSink{}, clock)

	if d := l.Admit("install-a"); !d.Allowed {
		t.Fatal("first call denied")
	}
	if d := l.Admit("install-a"); d.Allowed {
		t.Fatal("second call on the same day allowed")
	}

	advance(2 * time.Hour)
	if d := l.Admit("install-a"); !d.Allowed {
		t.Fatalf("call on the next day denied: %+v", d)
	}
}

func TestGlobalCapAppliesAcrossInstalls(t *testing.T) {
	clock, _ := newClock(time.Unix(1_700_000_000, 0).UTC())
	l := New(Limits{Daily: 100, Burst: 100, GlobalDaily: 2}, &fakeSink{}, clock)

	l.Admit("install-a")
	l.Admit("install-b")

	d := l.Admit("install-c")
	if d.Allowed || d.Reason != ReasonGlobal {
		t.Fatalf("third call = %+v, want denied with ReasonGlobal", d)
	}
}

func TestFlushPersistsAndClearsPending(t *testing.T) {
	clock, _ := newClock(time.Unix(1_700_000_000, 0).UTC())
	sink := &fakeSink{}
	l := New(Limits{Daily: 100, Burst: 100, GlobalDaily: 1000}, sink, clock)
	l.Admit("install-a")
	l.Admit("install-a")

	if err := l.Flush(context.Background()); err != nil {
		t.Fatalf("Flush() error = %v", err)
	}
	if sink.calls != 2 {
		t.Fatalf("persisted calls = %d, want 2", sink.calls)
	}

	if err := l.Flush(context.Background()); err != nil {
		t.Fatalf("second Flush() error = %v", err)
	}
	if sink.calls != 2 {
		t.Fatalf("persisted calls after empty flush = %d, want 2", sink.calls)
	}
}

func TestHydrateRestoresDailyCountsSoLimitIsEnforced(t *testing.T) {
	clock, _ := newClock(time.Unix(1_700_000_000, 0).UTC())
	sink := &fakeSink{
		usage: map[string]map[string]int64{
			"2023-11-14": {"install-a": 2},
		},
	}
	l := New(Limits{Daily: 2, Burst: 100, GlobalDaily: 1000}, sink, clock)

	if err := l.Hydrate(context.Background()); err != nil {
		t.Fatalf("Hydrate() error = %v", err)
	}

	d := l.Admit("install-a")
	if d.Allowed || d.Reason != ReasonDaily {
		t.Fatalf("call after hydrate at limit = %+v, want denied with ReasonDaily", d)
	}
}

func TestHydrateSeedsGlobalCounterFromSum(t *testing.T) {
	clock, _ := newClock(time.Unix(1_700_000_000, 0).UTC())
	sink := &fakeSink{
		usage: map[string]map[string]int64{
			"2023-11-14": {
				"install-a": 5,
				"install-b": 3,
			},
		},
	}
	l := New(Limits{Daily: 100, Burst: 100, GlobalDaily: 10}, sink, clock)

	if err := l.Hydrate(context.Background()); err != nil {
		t.Fatalf("Hydrate() error = %v", err)
	}

	l.Admit("install-c")
	l.Admit("install-c")

	d := l.Admit("install-d")
	if d.Allowed || d.Reason != ReasonGlobal {
		t.Fatalf("call after hydrate with global sum = %+v, want denied with ReasonGlobal", d)
	}
}

func TestHydrateDoesNotPopulatePending(t *testing.T) {
	clock, _ := newClock(time.Unix(1_700_000_000, 0).UTC())
	sink := &fakeSink{
		usage: map[string]map[string]int64{
			"2023-11-14": {"install-a": 5},
		},
	}
	l := New(Limits{Daily: 100, Burst: 100, GlobalDaily: 1000}, sink, clock)

	if err := l.Hydrate(context.Background()); err != nil {
		t.Fatalf("Hydrate() error = %v", err)
	}

	oldCalls := sink.calls
	if err := l.Flush(context.Background()); err != nil {
		t.Fatalf("Flush() error = %v", err)
	}

	if sink.calls != oldCalls {
		t.Fatalf("flush after hydrate persisted %d calls, want 0", sink.calls-oldCalls)
	}
}

func TestRecordTokensUsesDayFromDecision(t *testing.T) {
	clock, advance := newClock(time.Date(2026, 10, 2, 23, 59, 50, 0, time.UTC))
	sink := &fakeSink{}
	l := New(Limits{Daily: 100, Burst: 100, GlobalDaily: 1000}, sink, clock)

	d := l.Admit("install-a")
	advance(15 * time.Second)
	l.RecordTokens("install-a", d.Day, 1000)

	if err := l.Flush(context.Background()); err != nil {
		t.Fatalf("Flush() error = %v", err)
	}

	got := sink.usage["2026-10-02"]["install-a"]
	if got != 1 {
		t.Fatalf("calls on 2026-10-02 = %d, want 1", got)
	}
	if sink.usage["2026-10-03"] != nil {
		t.Fatalf("unexpected calls on 2026-10-03: %v", sink.usage["2026-10-03"])
	}
}

func TestFlushErrorIsLogged(t *testing.T) {
	clock, _ := newClock(time.Unix(1_700_000_000, 0).UTC())
	sink := &fakeSink{flushErr: context.DeadlineExceeded}
	l := New(Limits{Daily: 100, Burst: 100, GlobalDaily: 1000}, sink, clock)
	l.Admit("install-a")

	var buf safeBuffer
	logger := slog.New(slog.NewTextHandler(&buf, nil))

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		l.RunFlusher(ctx, 10*time.Millisecond, logger)
		close(done)
	}()

	time.Sleep(50 * time.Millisecond)
	cancel()
	<-done

	logged := buf.String()
	if !contains(logged, "flush failed") {
		t.Fatalf("log output missing 'flush failed': %s", logged)
	}
	if !contains(logged, "consecutive_failures") {
		t.Fatalf("log output missing 'consecutive_failures': %s", logged)
	}
}

type safeBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (sb *safeBuffer) Write(p []byte) (n int, err error) {
	sb.mu.Lock()
	defer sb.mu.Unlock()
	return sb.buf.Write(p)
}

func (sb *safeBuffer) String() string {
	sb.mu.Lock()
	defer sb.mu.Unlock()
	return sb.buf.String()
}

func TestEvictStaleDropsPreviousDayButKeepsToday(t *testing.T) {
	clock, advance := newClock(time.Date(2026, 10, 2, 23, 0, 0, 0, time.UTC))
	l := New(Limits{Daily: 100, Burst: 100, GlobalDaily: 1000}, &fakeSink{}, clock)

	l.Admit("install-a")
	advance(2 * time.Hour)
	l.Admit("install-b")

	day := clock().UTC().Format("2006-01-02")
	l.mu.Lock()
	l.evictStale(day)
	_, hasA := l.installs["install-a"]
	_, hasB := l.installs["install-b"]
	l.mu.Unlock()

	if hasA {
		t.Fatal("install-a from previous day was not evicted")
	}
	if !hasB {
		t.Fatal("install-b from today was evicted")
	}
}

func TestDeniedCallDoesNotIncrementCounters(t *testing.T) {
	clock, _ := newClock(time.Unix(1_700_000_000, 0).UTC())

	testCases := []struct {
		name   string
		limits Limits
		setup  func(*Limiter)
		reason Reason
	}{
		{
			name:   "burst denial",
			limits: Limits{Daily: 100, Burst: 1, GlobalDaily: 1000},
			setup: func(l *Limiter) {
				l.Admit("install-a")
			},
			reason: ReasonBurst,
		},
		{
			name:   "daily denial",
			limits: Limits{Daily: 1, Burst: 100, GlobalDaily: 1000},
			setup: func(l *Limiter) {
				l.Admit("install-a")
			},
			reason: ReasonDaily,
		},
		{
			name:   "global denial",
			limits: Limits{Daily: 100, Burst: 100, GlobalDaily: 1},
			setup: func(l *Limiter) {
				l.Admit("install-a")
			},
			reason: ReasonGlobal,
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			sink := &fakeSink{}
			l := New(tc.limits, sink, clock)
			tc.setup(l)

			callsBefore := sink.calls
			d := l.Admit("install-a")

			if d.Allowed {
				t.Fatal("denial test admitted a call")
			}
			if d.Reason != tc.reason {
				t.Fatalf("Reason = %v, want %v", d.Reason, tc.reason)
			}

			if err := l.Flush(context.Background()); err != nil {
				t.Fatalf("Flush() error = %v", err)
			}

			if sink.calls != callsBefore+1 {
				t.Fatalf("denied call incremented counter: before=%d after=%d", callsBefore, sink.calls)
			}
		})
	}
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(s) > len(substr) && containsAt(s, substr, 0))
}

func containsAt(s, substr string, start int) bool {
	for i := start; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}
