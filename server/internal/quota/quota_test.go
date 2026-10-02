package quota

import (
	"context"
	"testing"
	"time"
)

type fakeSink struct {
	calls int64
}

func (f *fakeSink) PersistUsage(_ context.Context, deltas []Delta) error {
	for _, d := range deltas {
		f.calls += d.Calls
	}
	return nil
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
