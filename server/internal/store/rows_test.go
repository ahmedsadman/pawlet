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

func TestEarliestDaysModelStats(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	seedRows(t, s)

	for _, step := range []struct{ insert, want string }{
		{`INSERT INTO model_stats_daily (id_hash, day, app_version_code, accepted, declined, unavailable)
		  VALUES ('a', '2026-09-20', 20, 1, 0, 0)`, "2026-09-20"},
		{`INSERT INTO model_stats_rollup (day, app_version_code, accepted, declined, unavailable, install_count)
		  VALUES ('2026-06-01', 19, 1, 0, 0, 1)`, "2026-06-01"},
	} {
		if _, err := s.write.ExecContext(ctx, step.insert); err != nil {
			t.Fatalf("seed: %v", err)
		}
		got, err := s.EarliestDays(ctx)
		if err != nil {
			t.Fatalf("EarliestDays() error = %v", err)
		}
		if got.ModelStats != step.want || got.Any() != step.want {
			t.Fatalf("EarliestDays() = %+v (Any %q), want model stats %s", got, got.Any(), step.want)
		}
	}
}

// seedModelRows writes model stats straight to the tables: pawletd's writer
// is not part of this package's read API.
func seedModelRows(t *testing.T, s *Store) {
	t.Helper()
	ctx := context.Background()
	for _, q := range []string{
		`INSERT INTO model_stats_daily (id_hash, day, app_version_code, accepted, declined, unavailable) VALUES
		   ('a', '2026-10-01', 20, 8, 2, 0),
		   ('a', '2026-10-02', 20, 5, 1, 1),
		   ('a', '2026-10-02', 21, 3, 0, 0),
		   ('b', '2026-10-03', 21, 7, 3, 0)`,
		`INSERT INTO model_stats_rollup (day, app_version_code, accepted, declined, unavailable, install_count) VALUES
		   ('2026-06-01', 19, 40, 10, 2, 3),
		   ('2026-06-02', 19, 30, 10, 0, 2)`,
		`INSERT INTO installs (id_hash, first_seen, last_seen, messages_archived) VALUES
		   ('a', 1, 1, 120),
		   ('b', 1, 1, 0)`,
	} {
		if _, err := s.write.ExecContext(ctx, q); err != nil {
			t.Fatalf("seed model rows: %v", err)
		}
	}
}

func TestModelStatsLoaders(t *testing.T) {
	s := newTestStore(t)
	seedModelRows(t, s)
	ctx := context.Background()

	all, err := s.AllModelStats(ctx)
	if err != nil || len(all) != 4 || all[0] != (ModelRow{IDHash: "a", Day: "2026-10-01", AppVersionCode: 20, Accepted: 8, Declined: 2}) {
		t.Fatalf("AllModelStats() = %+v, %v", all, err)
	}
	between, err := s.ModelStatsBetween(ctx, "2026-10-02", "2026-10-03")
	if err != nil || len(between) != 3 || between[0].AppVersionCode != 20 || between[1].AppVersionCode != 21 || between[2].IDHash != "b" {
		t.Fatalf("ModelStatsBetween() = %+v, %v", between, err)
	}
	rollup, err := s.ModelRollupBetween(ctx, "2026-06-01", "2026-06-01")
	want := ModelRollupRow{Day: "2026-06-01", AppVersionCode: 19, Accepted: 40, Declined: 10, Unavailable: 2, InstallCount: 3}
	if err != nil || len(rollup) != 1 || rollup[0] != want {
		t.Fatalf("ModelRollupBetween() = %+v, %v", rollup, err)
	}
	archived, err := s.MessagesArchived(ctx)
	if err != nil || len(archived) != 1 || archived["a"] != 120 {
		t.Fatalf("MessagesArchived() = %v, %v (installs with 0 are left out)", archived, err)
	}
	for hash, want := range map[string]int64{"a": 120, "b": 0, "missing": 0} {
		if n, err := s.MessagesArchivedFor(ctx, hash); err != nil || n != want {
			t.Fatalf("MessagesArchivedFor(%q) = %d, %v, want %d", hash, n, err, want)
		}
	}
}

func TestModelStatsLoadersEmpty(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	if rows, err := s.AllModelStats(ctx); err != nil || len(rows) != 0 {
		t.Fatalf("AllModelStats() = %+v, %v", rows, err)
	}
	if rows, err := s.ModelRollupBetween(ctx, "2026-01-01", "2026-12-31"); err != nil || len(rows) != 0 {
		t.Fatalf("ModelRollupBetween() = %+v, %v", rows, err)
	}
	if m, err := s.MessagesArchived(ctx); err != nil || len(m) != 0 {
		t.Fatalf("MessagesArchived() = %v, %v", m, err)
	}
}
