package store

import (
	"context"
	"testing"
)

func usageOf(t *testing.T, s *Store, idHash, day string) UsageRow {
	t.Helper()
	u, err := s.Usage(context.Background(), idHash, day)
	if err != nil {
		t.Fatalf("Usage() error = %v", err)
	}
	return u
}

func countMessage(t *testing.T, s *Store, idHash, day, key string) bool {
	t.Helper()
	counted, err := s.CountLLMMessage(context.Background(), idHash, day, key)
	if err != nil {
		t.Fatalf("CountLLMMessage() error = %v", err)
	}
	return counted
}

func TestAddUsageAccumulates(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()

	if err := s.AddUsage(ctx, []UsageDelta{{IDHash: "a", Day: "2026-10-02", Attempts: 3, Tokens: 120}}); err != nil {
		t.Fatalf("AddUsage() error = %v", err)
	}
	if err := s.AddUsage(ctx, []UsageDelta{{IDHash: "a", Day: "2026-10-02", Attempts: 2, Tokens: 80}}); err != nil {
		t.Fatalf("second AddUsage() error = %v", err)
	}

	u := usageOf(t, s, "a", "2026-10-02")
	if u.Attempts != 5 || u.Tokens != 200 {
		t.Fatalf("attempts, tokens = %d, %d; want 5, 200", u.Attempts, u.Tokens)
	}
}

func TestAddUsageLeavesCallsAlone(t *testing.T) {
	s := newTestStore(t)
	countMessage(t, s, "a", "2026-10-02", "k1")

	if err := s.AddUsage(context.Background(), []UsageDelta{{IDHash: "a", Day: "2026-10-02", Attempts: 3}}); err != nil {
		t.Fatalf("AddUsage() error = %v", err)
	}

	u := usageOf(t, s, "a", "2026-10-02")
	if u.Calls != 1 || u.Attempts != 3 {
		t.Fatalf("calls, attempts = %d, %d; want 1, 3", u.Calls, u.Attempts)
	}
}

func TestAddUsageSeparatesDays(t *testing.T) {
	s := newTestStore(t)

	err := s.AddUsage(context.Background(), []UsageDelta{
		{IDHash: "a", Day: "2026-10-02", Attempts: 1},
		{IDHash: "a", Day: "2026-10-03", Attempts: 7},
	})
	if err != nil {
		t.Fatalf("AddUsage() error = %v", err)
	}

	if u := usageOf(t, s, "a", "2026-10-03"); u.Attempts != 7 {
		t.Fatalf("attempts = %d, want 7", u.Attempts)
	}
}

func TestUsageMissingIsZero(t *testing.T) {
	s := newTestStore(t)

	if u := usageOf(t, s, "nobody", "2026-10-02"); u != (UsageRow{IDHash: "nobody", Day: "2026-10-02"}) {
		t.Fatalf("Usage() = %+v, want zero counts", u)
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

	err := s.AddUsage(context.Background(), []UsageDelta{
		{IDHash: "a", Day: "2026-10-02", Attempts: 2, Tokens: 30},
		{IDHash: "a", Day: "2026-10-02", Attempts: 3, Tokens: 40},
	})
	if err != nil {
		t.Fatalf("AddUsage() error = %v", err)
	}

	u := usageOf(t, s, "a", "2026-10-02")
	if u.Attempts != 5 || u.Tokens != 70 {
		t.Fatalf("attempts, tokens = %d, %d; want 5, 70", u.Attempts, u.Tokens)
	}
}

func TestConcurrentFlushesDoNotConflict(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()

	const flushes = 8
	errs := make(chan error, flushes)
	for i := 0; i < flushes; i++ {
		go func() {
			errs <- s.AddUsage(ctx, []UsageDelta{{IDHash: "a", Day: "2026-10-02", Attempts: 1}})
		}()
	}
	for i := 0; i < flushes; i++ {
		if err := <-errs; err != nil {
			t.Fatalf("concurrent AddUsage() error = %v", err)
		}
	}

	if u := usageOf(t, s, "a", "2026-10-02"); u.Attempts != flushes {
		t.Fatalf("attempts = %d, want %d", u.Attempts, flushes)
	}
}

func TestUsageForDayReturnsAttemptsPerInstall(t *testing.T) {
	s := newTestStore(t)

	err := s.AddUsage(context.Background(), []UsageDelta{
		{IDHash: "install-a", Day: "2026-10-02", Attempts: 5},
		{IDHash: "install-b", Day: "2026-10-02", Attempts: 3},
		{IDHash: "install-c", Day: "2026-10-03", Attempts: 7},
	})
	if err != nil {
		t.Fatalf("AddUsage() error = %v", err)
	}
	// Distinct messages must not leak into the quota's view.
	countMessage(t, s, "install-a", "2026-10-02", "k1")

	usage, err := s.UsageForDay(context.Background(), "2026-10-02")
	if err != nil {
		t.Fatalf("UsageForDay() error = %v", err)
	}

	if len(usage) != 2 {
		t.Fatalf("len(usage) = %d, want 2", len(usage))
	}
	if usage["install-a"] != 5 {
		t.Errorf("usage[install-a] = %d, want 5", usage["install-a"])
	}
	if usage["install-b"] != 3 {
		t.Errorf("usage[install-b] = %d, want 3", usage["install-b"])
	}
	if _, present := usage["install-c"]; present {
		t.Error("usage contains install-c from different day")
	}
}

func TestUsageForDayEmptyWhenNothingPersisted(t *testing.T) {
	s := newTestStore(t)

	usage, err := s.UsageForDay(context.Background(), "2026-10-02")
	if err != nil {
		t.Fatalf("UsageForDay() error = %v", err)
	}
	if len(usage) != 0 {
		t.Fatalf("len(usage) = %d, want 0", len(usage))
	}
}

func TestCountLLMMessageCountsEachKeyOnce(t *testing.T) {
	s := newTestStore(t)

	if !countMessage(t, s, "a", "2026-10-02", "k1") {
		t.Fatal("first sighting not counted")
	}
	if countMessage(t, s, "a", "2026-10-02", "k1") {
		t.Fatal("retry of k1 counted again")
	}
	if !countMessage(t, s, "a", "2026-10-02", "k2") {
		t.Fatal("a different key was not counted")
	}

	if u := usageOf(t, s, "a", "2026-10-02"); u.Calls != 2 {
		t.Fatalf("calls = %d, want 2", u.Calls)
	}
}

func TestCountLLMMessageWithoutKeyCountsEveryCall(t *testing.T) {
	s := newTestStore(t)

	countMessage(t, s, "a", "2026-10-02", "")
	countMessage(t, s, "a", "2026-10-02", "")

	if u := usageOf(t, s, "a", "2026-10-02"); u.Calls != 2 {
		t.Fatalf("calls = %d, want 2", u.Calls)
	}
}

func TestCountLLMMessageKeysArePerInstall(t *testing.T) {
	s := newTestStore(t)

	countMessage(t, s, "a", "2026-10-02", "k1")
	if !countMessage(t, s, "b", "2026-10-02", "k1") {
		t.Fatal("same key from another install not counted")
	}
}

func TestCountLLMMessageCreditsTheFirstDay(t *testing.T) {
	s := newTestStore(t)

	countMessage(t, s, "a", "2026-10-02", "k1")
	if countMessage(t, s, "a", "2026-10-03", "k1") {
		t.Fatal("next-day retry counted again")
	}

	if u := usageOf(t, s, "a", "2026-10-02"); u.Calls != 1 {
		t.Errorf("first day calls = %d, want 1", u.Calls)
	}
	if u := usageOf(t, s, "a", "2026-10-03"); u.Calls != 0 {
		t.Errorf("retry day calls = %d, want 0", u.Calls)
	}
}

func TestPruneLLMMessagesDropsKeysBeforeDay(t *testing.T) {
	s := newTestStore(t)
	countMessage(t, s, "a", "2026-09-01", "old")
	countMessage(t, s, "a", "2026-10-01", "kept")

	n, err := s.PruneLLMMessages(context.Background(), "2026-10-01")
	if err != nil {
		t.Fatalf("PruneLLMMessages() error = %v", err)
	}
	if n != 1 {
		t.Fatalf("pruned = %d, want 1", n)
	}
	if countMessage(t, s, "a", "2026-10-02", "kept") {
		t.Error("kept key counted again after prune")
	}
	// Past retention a key is forgotten, so a very late retry counts anew.
	if !countMessage(t, s, "a", "2026-10-02", "old") {
		t.Error("pruned key not counted on its next sighting")
	}
}
