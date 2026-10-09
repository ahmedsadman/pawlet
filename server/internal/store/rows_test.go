package store

import (
	"context"
	"testing"
	"time"
)

func seedRows(t *testing.T, s *Store) {
	t.Helper()
	ctx := context.Background()
	d1 := time.Date(2026, 10, 1, 9, 0, 0, 0, time.UTC)
	d3 := time.Date(2026, 10, 3, 9, 0, 0, 0, time.UTC)
	if err := s.TouchInstall(ctx, "b", d3, InstallMeta{AppVersionCode: 18}); err != nil {
		t.Fatalf("touch b: %v", err)
	}
	if err := s.TouchInstall(ctx, "a", d1, InstallMeta{AppVersionCode: 17, DeviceTier: "DEVICE"}); err != nil {
		t.Fatalf("touch a: %v", err)
	}
	if err := s.AddUsage(ctx, []UsageDelta{
		{IDHash: "a", Day: "2026-10-01", Calls: 3, Tokens: 30},
		{IDHash: "a", Day: "2026-10-02", Calls: 1, Tokens: 10},
		{IDHash: "b", Day: "2026-10-03", Calls: 5, Tokens: 50},
	}); err != nil {
		t.Fatalf("usage: %v", err)
	}
	if err := s.AddCounters(ctx, []CounterDelta{
		{Day: "2026-10-02", Metric: "classify_outcome", Key: "ok", Count: 4},
		{Day: "2026-10-03", Metric: "model", Key: "m", Count: 2},
	}); err != nil {
		t.Fatalf("counters: %v", err)
	}
}

func TestAllInstallsOrderedByFirstSeen(t *testing.T) {
	s := newTestStore(t)
	seedRows(t, s)

	got, err := s.AllInstalls(context.Background())
	if err != nil {
		t.Fatalf("AllInstalls() error = %v", err)
	}
	if len(got) != 2 || got[0].IDHash != "a" || got[1].IDHash != "b" {
		t.Fatalf("AllInstalls() = %+v, want a then b", got)
	}
	if got[0].Meta.DeviceTier != "DEVICE" || got[1].Meta.AppVersionCode != 18 {
		t.Fatalf("meta not loaded: %+v", got)
	}
}

func TestUsageLoaders(t *testing.T) {
	s := newTestStore(t)
	seedRows(t, s)
	ctx := context.Background()

	all, err := s.AllUsage(ctx)
	if err != nil || len(all) != 3 {
		t.Fatalf("AllUsage() = %+v, %v; want 3 rows", all, err)
	}
	between, err := s.UsageBetween(ctx, "2026-10-02", "2026-10-03")
	if err != nil || len(between) != 2 || between[0].Day != "2026-10-02" || between[1].IDHash != "b" {
		t.Fatalf("UsageBetween() = %+v, %v", between, err)
	}
	mine, err := s.UsageForInstall(ctx, "a")
	if err != nil || len(mine) != 2 || mine[1] != (UsageRow{IDHash: "a", Day: "2026-10-02", Calls: 1, Tokens: 10}) {
		t.Fatalf("UsageForInstall() = %+v, %v", mine, err)
	}
}

func TestInstallDaysBetween(t *testing.T) {
	s := newTestStore(t)
	seedRows(t, s)

	got, err := s.InstallDaysBetween(context.Background(), "2026-10-01", "2026-10-02")
	if err != nil {
		t.Fatalf("InstallDaysBetween() error = %v", err)
	}
	if len(got) != 1 || got[0] != (DayRow{IDHash: "a", Day: "2026-10-01", AppVersionCode: 17}) {
		t.Fatalf("InstallDaysBetween() = %+v", got)
	}
}

func TestCountersBetween(t *testing.T) {
	s := newTestStore(t)
	seedRows(t, s)

	got, err := s.CountersBetween(context.Background(), "2026-10-03", "2026-10-03")
	if err != nil {
		t.Fatalf("CountersBetween() error = %v", err)
	}
	if len(got) != 1 || got[0] != (CounterRow{Day: "2026-10-03", Metric: "model", Key: "m", Count: 2}) {
		t.Fatalf("CountersBetween() = %+v", got)
	}
}

func TestEarliestDays(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()

	empty, err := s.EarliestDays(ctx)
	if err != nil {
		t.Fatalf("EarliestDays() error = %v", err)
	}
	if empty != (EarliestDays{}) || empty.Any() != "" {
		t.Fatalf("empty EarliestDays = %+v", empty)
	}

	seedRows(t, s)
	got, err := s.EarliestDays(ctx)
	if err != nil {
		t.Fatalf("EarliestDays() error = %v", err)
	}
	want := EarliestDays{Usage: "2026-10-01", InstallDays: "2026-10-01", Counters: "2026-10-02", FirstSeen: "2026-10-01"}
	if got != want {
		t.Fatalf("EarliestDays() = %+v, want %+v", got, want)
	}
	if got.Any() != "2026-10-01" {
		t.Fatalf("Any() = %q", got.Any())
	}
}
