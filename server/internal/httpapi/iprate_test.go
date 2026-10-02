package httpapi

import (
	"testing"
	"time"
)

func TestHourlyLimiterCapacity(t *testing.T) {
	now := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	lim := newHourlyLimiter(3, func() time.Time { return now })

	// First three requests should succeed.
	for i := 0; i < 3; i++ {
		if !lim.allow("192.0.2.1") {
			t.Fatalf("request %d was denied, want allowed", i+1)
		}
	}

	// Fourth request should be denied.
	if lim.allow("192.0.2.1") {
		t.Fatal("fourth request allowed, want denied")
	}
}

func TestHourlyLimiterPerAddress(t *testing.T) {
	now := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	lim := newHourlyLimiter(2, func() time.Time { return now })

	// Two IPs, each gets their own quota.
	if !lim.allow("192.0.2.1") {
		t.Fatal("first IP first request denied")
	}
	if !lim.allow("192.0.2.2") {
		t.Fatal("second IP first request denied")
	}
	if !lim.allow("192.0.2.1") {
		t.Fatal("first IP second request denied")
	}
	if !lim.allow("192.0.2.2") {
		t.Fatal("second IP second request denied")
	}

	// Both IPs are now at capacity.
	if lim.allow("192.0.2.1") {
		t.Fatal("first IP third request allowed, want denied")
	}
	if lim.allow("192.0.2.2") {
		t.Fatal("second IP third request allowed, want denied")
	}
}

func TestHourlyLimiterNewHourResets(t *testing.T) {
	now := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	clock := &fakeClock{current: now}
	lim := newHourlyLimiter(1, clock.now)

	// Consume the single-request quota.
	if !lim.allow("192.0.2.1") {
		t.Fatal("first request denied")
	}
	if lim.allow("192.0.2.1") {
		t.Fatal("second request allowed, want denied")
	}

	// Advance to the next hour.
	clock.current = now.Add(61 * time.Minute)

	// The limit should reset.
	if !lim.allow("192.0.2.1") {
		t.Fatal("first request in new hour denied, want allowed")
	}
	if lim.allow("192.0.2.1") {
		t.Fatal("second request in new hour allowed, want denied")
	}
}

func TestHourlyLimiterPruneDropsStale(t *testing.T) {
	now := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	clock := &fakeClock{current: now}
	lim := newHourlyLimiter(5, clock.now)

	// Consume quota from two addresses in hour 12.
	lim.allow("192.0.2.1")
	lim.allow("192.0.2.2")

	// Advance to hour 13 and hit a third address.
	clock.current = now.Add(61 * time.Minute)
	lim.allow("192.0.2.3")

	// Before prune, all three entries exist.
	lim.mu.Lock()
	if len(lim.entries) != 3 {
		t.Fatalf("before prune: entries = %d, want 3", len(lim.entries))
	}
	lim.mu.Unlock()

	// Prune should drop the two hour-12 entries but keep the hour-13 entry.
	lim.Prune()

	lim.mu.Lock()
	defer lim.mu.Unlock()
	if len(lim.entries) != 1 {
		t.Fatalf("after prune: entries = %d, want 1", len(lim.entries))
	}
	if _, exists := lim.entries["192.0.2.3"]; !exists {
		t.Fatal("prune dropped the current-hour entry")
	}
}

func TestHourlyLimiterPruneKeepsCurrentHour(t *testing.T) {
	now := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	clock := &fakeClock{current: now}
	lim := newHourlyLimiter(5, clock.now)

	// Consume quota from one address.
	lim.allow("192.0.2.1")

	// Prune without advancing the clock. The entry should NOT be dropped.
	lim.Prune()

	lim.mu.Lock()
	defer lim.mu.Unlock()
	if len(lim.entries) != 1 {
		t.Fatalf("prune dropped current-hour entry: entries = %d, want 1", len(lim.entries))
	}
}

func TestFirstRequestAllowed(t *testing.T) {
	now := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	lim := newHourlyLimiter(1, func() time.Time { return now })

	// The very first request from a new address must be allowed, even with
	// capacity=1. An off-by-one here would break every client's first
	// attestation.
	if !lim.allow("192.0.2.1") {
		t.Fatal("first request from new address denied, want allowed")
	}
}

type fakeClock struct {
	current time.Time
}

func (c *fakeClock) now() time.Time {
	return c.current
}
