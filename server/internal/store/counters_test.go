package store

import (
	"context"
	"testing"
)

func TestAddCountersAccumulates(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()

	batch := []CounterDelta{{Day: "2026-10-09", Metric: "classify_outcome", Key: "ok", Count: 3}}
	if err := s.AddCounters(ctx, batch); err != nil {
		t.Fatalf("AddCounters() error = %v", err)
	}
	if err := s.AddCounters(ctx, batch); err != nil {
		t.Fatalf("second AddCounters() error = %v", err)
	}

	got, err := s.Counter(ctx, "2026-10-09", "classify_outcome", "ok")
	if err != nil {
		t.Fatalf("Counter() error = %v", err)
	}
	if got != 6 {
		t.Fatalf("count = %d, want 6", got)
	}
}

func TestAddCountersSeparatesDayMetricKey(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()

	err := s.AddCounters(ctx, []CounterDelta{
		{Day: "2026-10-09", Metric: "classify_outcome", Key: "ok", Count: 1},
		{Day: "2026-10-09", Metric: "classify_outcome", Key: "capacity", Count: 2},
		{Day: "2026-10-09", Metric: "session_outcome", Key: "ok", Count: 4},
		{Day: "2026-10-10", Metric: "classify_outcome", Key: "ok", Count: 8},
	})
	if err != nil {
		t.Fatalf("AddCounters() error = %v", err)
	}

	cases := []struct {
		day, metric, key string
		want             int64
	}{
		{"2026-10-09", "classify_outcome", "ok", 1},
		{"2026-10-09", "classify_outcome", "capacity", 2},
		{"2026-10-09", "session_outcome", "ok", 4},
		{"2026-10-10", "classify_outcome", "ok", 8},
	}
	for _, c := range cases {
		got, err := s.Counter(ctx, c.day, c.metric, c.key)
		if err != nil {
			t.Fatalf("Counter(%s,%s,%s) error = %v", c.day, c.metric, c.key, err)
		}
		if got != c.want {
			t.Errorf("Counter(%s,%s,%s) = %d, want %d", c.day, c.metric, c.key, got, c.want)
		}
	}
}

func TestCounterMissingIsZero(t *testing.T) {
	s := newTestStore(t)

	got, err := s.Counter(context.Background(), "2026-10-09", "model", "absent")
	if err != nil {
		t.Fatalf("Counter() error = %v", err)
	}
	if got != 0 {
		t.Fatalf("count = %d, want 0", got)
	}
}

func TestAddCountersEmptyIsNoOp(t *testing.T) {
	s := newTestStore(t)

	if err := s.AddCounters(context.Background(), nil); err != nil {
		t.Fatalf("AddCounters(nil) error = %v", err)
	}
}
