package httpapi

import (
	"testing"
	"time"
)

func TestRollingLimiterCapsPerKey(t *testing.T) {
	clock := &fakeClock{current: time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)}
	lim := NewRollingLimiter(3, time.Hour, clock.now)

	for i := 0; i < 3; i++ {
		if ok, _ := lim.Allow("a"); !ok {
			t.Fatalf("request %d denied, want allowed", i+1)
		}
	}
	ok, retry := lim.Allow("a")
	if ok {
		t.Fatal("fourth request allowed, want denied")
	}
	if retry != time.Hour {
		t.Errorf("retry = %v, want 1h (all hits at the same instant)", retry)
	}
	if ok, _ := lim.Allow("b"); !ok {
		t.Fatal("other key denied, want its own allowance")
	}
}

func TestRollingLimiterWindowRollsNotResets(t *testing.T) {
	start := time.Date(2026, 10, 3, 12, 50, 0, 0, time.UTC)
	clock := &fakeClock{current: start}
	lim := NewRollingLimiter(2, time.Hour, clock.now)

	lim.Allow("a") // 12:50
	clock.current = start.Add(20 * time.Minute)
	lim.Allow("a") // 13:10

	// 13:20 is a new clock hour, but both hits are inside the last hour.
	clock.current = start.Add(30 * time.Minute)
	ok, retry := lim.Allow("a")
	if ok {
		t.Fatal("allowed at 13:20, want denied (rolling, not clock-hour)")
	}
	if retry != 30*time.Minute {
		t.Errorf("retry = %v, want 30m (until the 12:50 hit expires)", retry)
	}

	// At 13:50 the 12:50 hit has left the window.
	clock.current = start.Add(time.Hour)
	if ok, _ := lim.Allow("a"); !ok {
		t.Fatal("denied at 13:50, want allowed once the oldest hit expired")
	}
	if ok, _ := lim.Allow("a"); ok {
		t.Fatal("allowed a third hit inside the window, want denied")
	}
}

func TestRollingLimiterDeniedRequestsDoNotCount(t *testing.T) {
	start := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	clock := &fakeClock{current: start}
	lim := NewRollingLimiter(1, time.Hour, clock.now)

	lim.Allow("a")
	clock.current = start.Add(30 * time.Minute)
	lim.Allow("a") // denied; must not extend the window

	clock.current = start.Add(time.Hour)
	if ok, _ := lim.Allow("a"); !ok {
		t.Fatal("denied an hour after the only admitted hit, want allowed")
	}
}

func TestRollingLimiterPruneDropsIdleKeys(t *testing.T) {
	start := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	clock := &fakeClock{current: start}
	lim := NewRollingLimiter(5, time.Hour, clock.now)

	lim.Allow("old")
	clock.current = start.Add(40 * time.Minute)
	lim.Allow("fresh")

	clock.current = start.Add(70 * time.Minute)
	lim.Prune()

	if _, ok := lim.hits["old"]; ok {
		t.Error("idle key survived Prune")
	}
	if got := len(lim.hits["fresh"]); got != 1 {
		t.Errorf("fresh key has %d hits after Prune, want 1", got)
	}
}

func TestModelStatsLimiterAllowsTwelvePerHour(t *testing.T) {
	clock := &fakeClock{current: time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)}
	lim := NewModelStatsLimiter(clock.now)

	for i := 0; i < 12; i++ {
		if ok, _ := lim.Allow("a"); !ok {
			t.Fatalf("request %d denied, want allowed", i+1)
		}
	}
	if ok, _ := lim.Allow("a"); ok {
		t.Fatal("13th request allowed, want denied")
	}
}
