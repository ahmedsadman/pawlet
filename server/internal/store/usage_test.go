package store

import (
	"context"
	"testing"
)

func TestAddUsageAccumulates(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()

	if err := s.AddUsage(ctx, []UsageDelta{{IDHash: "a", Day: "2026-10-02", Calls: 3, Tokens: 120}}); err != nil {
		t.Fatalf("AddUsage() error = %v", err)
	}
	if err := s.AddUsage(ctx, []UsageDelta{{IDHash: "a", Day: "2026-10-02", Calls: 2, Tokens: 80}}); err != nil {
		t.Fatalf("second AddUsage() error = %v", err)
	}

	calls, tokens, err := s.Usage(ctx, "a", "2026-10-02")
	if err != nil {
		t.Fatalf("Usage() error = %v", err)
	}
	if calls != 5 || tokens != 200 {
		t.Fatalf("calls, tokens = %d, %d; want 5, 200", calls, tokens)
	}
}

func TestAddUsageSeparatesDays(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()

	err := s.AddUsage(ctx, []UsageDelta{
		{IDHash: "a", Day: "2026-10-02", Calls: 1},
		{IDHash: "a", Day: "2026-10-03", Calls: 7},
	})
	if err != nil {
		t.Fatalf("AddUsage() error = %v", err)
	}

	calls, _, err := s.Usage(ctx, "a", "2026-10-03")
	if err != nil {
		t.Fatalf("Usage() error = %v", err)
	}
	if calls != 7 {
		t.Fatalf("calls = %d, want 7", calls)
	}
}

func TestUsageMissingIsZero(t *testing.T) {
	s := newTestStore(t)

	calls, tokens, err := s.Usage(context.Background(), "nobody", "2026-10-02")
	if err != nil {
		t.Fatalf("Usage() error = %v", err)
	}
	if calls != 0 || tokens != 0 {
		t.Fatalf("calls, tokens = %d, %d; want 0, 0", calls, tokens)
	}
}

func TestAddUsageEmptyIsNoOp(t *testing.T) {
	s := newTestStore(t)

	if err := s.AddUsage(context.Background(), nil); err != nil {
		t.Fatalf("AddUsage(nil) error = %v", err)
	}
}

func TestAddUsageAccumulatesWithinOneBatch(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()

	err := s.AddUsage(ctx, []UsageDelta{
		{IDHash: "a", Day: "2026-10-02", Calls: 2, Tokens: 30},
		{IDHash: "a", Day: "2026-10-02", Calls: 3, Tokens: 40},
	})
	if err != nil {
		t.Fatalf("AddUsage() error = %v", err)
	}

	calls, tokens, err := s.Usage(ctx, "a", "2026-10-02")
	if err != nil {
		t.Fatalf("Usage() error = %v", err)
	}
	if calls != 5 || tokens != 70 {
		t.Fatalf("calls, tokens = %d, %d; want 5, 70", calls, tokens)
	}
}

func TestConcurrentFlushesDoNotConflict(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()

	const flushes = 8
	errs := make(chan error, flushes)
	for i := 0; i < flushes; i++ {
		go func() {
			errs <- s.AddUsage(ctx, []UsageDelta{{IDHash: "a", Day: "2026-10-02", Calls: 1}})
		}()
	}
	for i := 0; i < flushes; i++ {
		if err := <-errs; err != nil {
			t.Fatalf("concurrent AddUsage() error = %v", err)
		}
	}

	calls, _, err := s.Usage(ctx, "a", "2026-10-02")
	if err != nil {
		t.Fatalf("Usage() error = %v", err)
	}
	if calls != flushes {
		t.Fatalf("calls = %d, want %d", calls, flushes)
	}
}
