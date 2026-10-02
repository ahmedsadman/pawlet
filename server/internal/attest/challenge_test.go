package attest

import (
	"sync"
	"testing"
	"time"
)

func TestIssueReturnsDistinctHexValues(t *testing.T) {
	c := NewChallenges(2*time.Minute, time.Now)

	a, err := c.Issue()
	if err != nil {
		t.Fatalf("Issue() error = %v", err)
	}
	b, err := c.Issue()
	if err != nil {
		t.Fatalf("second Issue() error = %v", err)
	}

	if a == b {
		t.Fatal("two issued challenges are identical")
	}
	if len(a) != 64 {
		t.Fatalf("len(a) = %d, want 64 hex characters for 32 bytes", len(a))
	}
}

func TestConsumeSucceedsOnce(t *testing.T) {
	c := NewChallenges(2*time.Minute, time.Now)
	value, _ := c.Issue()

	if !c.Consume(value) {
		t.Fatal("first Consume() = false, want true")
	}
	if c.Consume(value) {
		t.Fatal("second Consume() = true, want false")
	}
}

func TestConsumeRejectsUnknown(t *testing.T) {
	c := NewChallenges(2*time.Minute, time.Now)

	if c.Consume("never-issued") {
		t.Fatal("Consume() = true for an unissued value")
	}
}

func TestConsumeRejectsExpired(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	clock := func() time.Time { return now }
	c := NewChallenges(2*time.Minute, clock)
	value, _ := c.Issue()

	now = now.Add(3 * time.Minute)

	if c.Consume(value) {
		t.Fatal("Consume() = true for an expired challenge")
	}
}

func TestConsumeIsAtomicUnderConcurrency(t *testing.T) {
	c := NewChallenges(2*time.Minute, time.Now)
	value, _ := c.Issue()

	var (
		wg        sync.WaitGroup
		mu        sync.Mutex
		successes int
	)
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if c.Consume(value) {
				mu.Lock()
				successes++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()

	if successes != 1 {
		t.Fatalf("successes = %d, want exactly 1", successes)
	}
}

func TestPruneDropsExpiredEntries(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	clock := func() time.Time { return now }
	c := NewChallenges(2*time.Minute, clock)
	if _, err := c.Issue(); err != nil {
		t.Fatalf("Issue() error = %v", err)
	}

	now = now.Add(3 * time.Minute)
	c.Prune()

	if got := c.Len(); got != 0 {
		t.Fatalf("Len() = %d, want 0", got)
	}
}
