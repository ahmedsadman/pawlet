package store

import (
	"context"
	"reflect"
	"testing"
	"time"
)

func TestReplaceModelStatsOverwritesOnResend(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()

	first := []ModelStatsDay{{Day: "2026-10-09", AppVersionCode: 21, Accepted: 4, Declined: 1, Unavailable: 0}}
	if err := s.ReplaceModelStats(ctx, "a", first); err != nil {
		t.Fatalf("ReplaceModelStats() error = %v", err)
	}
	resend := []ModelStatsDay{{Day: "2026-10-09", AppVersionCode: 21, Accepted: 7, Declined: 2, Unavailable: 1}}
	if err := s.ReplaceModelStats(ctx, "a", resend); err != nil {
		t.Fatalf("second ReplaceModelStats() error = %v", err)
	}
	// Resending the same totals again must not double them.
	if err := s.ReplaceModelStats(ctx, "a", resend); err != nil {
		t.Fatalf("third ReplaceModelStats() error = %v", err)
	}

	got, err := s.ModelStatsForInstall(ctx, "a")
	if err != nil {
		t.Fatalf("ModelStatsForInstall() error = %v", err)
	}
	if !reflect.DeepEqual(got, resend) {
		t.Fatalf("rows = %+v, want %+v", got, resend)
	}
}

func TestReplaceModelStatsKeysByInstallDayAndVersion(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()

	if err := s.ReplaceModelStats(ctx, "a", []ModelStatsDay{
		{Day: "2026-10-09", AppVersionCode: 22, Accepted: 2},
		{Day: "2026-10-08", AppVersionCode: 21, Accepted: 5},
		{Day: "2026-10-09", AppVersionCode: 21, Declined: 3},
	}); err != nil {
		t.Fatalf("ReplaceModelStats(a) error = %v", err)
	}
	if err := s.ReplaceModelStats(ctx, "b", []ModelStatsDay{
		{Day: "2026-10-09", AppVersionCode: 21, Unavailable: 9},
	}); err != nil {
		t.Fatalf("ReplaceModelStats(b) error = %v", err)
	}

	got, err := s.ModelStatsForInstall(ctx, "a")
	if err != nil {
		t.Fatalf("ModelStatsForInstall() error = %v", err)
	}
	want := []ModelStatsDay{
		{Day: "2026-10-08", AppVersionCode: 21, Accepted: 5},
		{Day: "2026-10-09", AppVersionCode: 21, Declined: 3},
		{Day: "2026-10-09", AppVersionCode: 22, Accepted: 2},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("rows for a = %+v, want %+v", got, want)
	}
}

func TestReplaceModelStatsEmptyIsNoOp(t *testing.T) {
	s := newTestStore(t)

	if err := s.ReplaceModelStats(context.Background(), "a", nil); err != nil {
		t.Fatalf("ReplaceModelStats(nil) error = %v", err)
	}
}

func TestModelStatsForUnknownInstallIsEmpty(t *testing.T) {
	s := newTestStore(t)

	got, err := s.ModelStatsForInstall(context.Background(), "absent")
	if err != nil || len(got) != 0 {
		t.Fatalf("ModelStatsForInstall() = %+v, %v; want empty, nil", got, err)
	}
}

// rollupRow mirrors one model_stats_rollup row for assertions.
type rollupRow struct {
	Day                             string
	AppVersionCode                  int64
	Accepted, Declined, Unavailable int64
	InstallCount                    int64
}

func readRollup(t *testing.T, s *Store) []rollupRow {
	t.Helper()
	rows, err := s.read.QueryContext(context.Background(),
		`SELECT day, app_version_code, accepted, declined, unavailable, install_count
		 FROM model_stats_rollup ORDER BY day, app_version_code`)
	if err != nil {
		t.Fatalf("query rollup: %v", err)
	}
	defer func() { _ = rows.Close() }()
	var out []rollupRow
	for rows.Next() {
		var r rollupRow
		if err := rows.Scan(&r.Day, &r.AppVersionCode, &r.Accepted, &r.Declined, &r.Unavailable, &r.InstallCount); err != nil {
			t.Fatalf("scan rollup: %v", err)
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("iterate rollup: %v", err)
	}
	return out
}

func messagesArchived(t *testing.T, s *Store, idHash string) int64 {
	t.Helper()
	var n int64
	if err := s.read.QueryRowContext(context.Background(),
		`SELECT messages_archived FROM installs WHERE id_hash = ?`, idHash).Scan(&n); err != nil {
		t.Fatalf("read messages_archived for %s: %v", idHash, err)
	}
	return n
}

// seedRollup creates installs a and b with rows on both sides of the cutoff
// for now = 2026-10-10 (cutoff day 2026-07-12: older rows fold, that day stays).
func seedRollup(t *testing.T, s *Store) time.Time {
	t.Helper()
	ctx := context.Background()
	now := time.Date(2026, 10, 10, 3, 0, 0, 0, time.UTC)
	for _, h := range []string{"a", "b"} {
		if err := s.TouchInstall(ctx, h, now, InstallMeta{}); err != nil {
			t.Fatalf("touch %s: %v", h, err)
		}
	}
	if err := s.ReplaceModelStats(ctx, "a", []ModelStatsDay{
		{Day: "2026-07-10", AppVersionCode: 20, Accepted: 10, Declined: 2, Unavailable: 1},
		{Day: "2026-07-11", AppVersionCode: 20, Accepted: 4, Declined: 1},
		{Day: "2026-07-12", AppVersionCode: 20, Accepted: 100}, // cutoff day: kept
	}); err != nil {
		t.Fatalf("seed a: %v", err)
	}
	if err := s.ReplaceModelStats(ctx, "b", []ModelStatsDay{
		{Day: "2026-07-10", AppVersionCode: 20, Accepted: 6, Declined: 3},
		{Day: "2026-07-10", AppVersionCode: 21, Accepted: 1, Unavailable: 2},
		{Day: "2026-10-09", AppVersionCode: 21, Accepted: 50},
	}); err != nil {
		t.Fatalf("seed b: %v", err)
	}
	return now
}

func TestRollupModelStatsFoldsArchivesAndDeletes(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	now := seedRollup(t, s)

	res, err := s.RollupModelStats(ctx, now)
	if err != nil {
		t.Fatalf("RollupModelStats() error = %v", err)
	}
	if res != (RollupResult{Rows: 4, Messages: 30}) {
		t.Errorf("result = %+v, want {Rows:4 Messages:30}", res)
	}

	wantRollup := []rollupRow{
		{Day: "2026-07-10", AppVersionCode: 20, Accepted: 16, Declined: 5, Unavailable: 1, InstallCount: 2},
		{Day: "2026-07-10", AppVersionCode: 21, Accepted: 1, Unavailable: 2, InstallCount: 1},
		{Day: "2026-07-11", AppVersionCode: 20, Accepted: 4, Declined: 1, InstallCount: 1},
	}
	if got := readRollup(t, s); !reflect.DeepEqual(got, wantRollup) {
		t.Errorf("rollup = %+v, want %+v", got, wantRollup)
	}

	if got := messagesArchived(t, s, "a"); got != 18 {
		t.Errorf("messages_archived(a) = %d, want 18", got)
	}
	if got := messagesArchived(t, s, "b"); got != 12 {
		t.Errorf("messages_archived(b) = %d, want 12", got)
	}

	a, err := s.ModelStatsForInstall(ctx, "a")
	if err != nil {
		t.Fatalf("ModelStatsForInstall(a) error = %v", err)
	}
	if want := []ModelStatsDay{{Day: "2026-07-12", AppVersionCode: 20, Accepted: 100}}; !reflect.DeepEqual(a, want) {
		t.Errorf("remaining rows for a = %+v, want %+v", a, want)
	}
	b, err := s.ModelStatsForInstall(ctx, "b")
	if err != nil {
		t.Fatalf("ModelStatsForInstall(b) error = %v", err)
	}
	if want := []ModelStatsDay{{Day: "2026-10-09", AppVersionCode: 21, Accepted: 50}}; !reflect.DeepEqual(b, want) {
		t.Errorf("remaining rows for b = %+v, want %+v", b, want)
	}
}

func TestRollupModelStatsIsIdempotent(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	now := seedRollup(t, s)

	if _, err := s.RollupModelStats(ctx, now); err != nil {
		t.Fatalf("first RollupModelStats() error = %v", err)
	}
	before := readRollup(t, s)

	res, err := s.RollupModelStats(ctx, now)
	if err != nil {
		t.Fatalf("second RollupModelStats() error = %v", err)
	}
	if res != (RollupResult{}) {
		t.Errorf("second result = %+v, want zero", res)
	}
	if got := readRollup(t, s); !reflect.DeepEqual(got, before) {
		t.Errorf("rollup changed on rerun: %+v, want %+v", got, before)
	}
	if got := messagesArchived(t, s, "a"); got != 18 {
		t.Errorf("messages_archived(a) = %d after rerun, want 18", got)
	}
}

func TestRollupModelStatsAddsToExistingRollupRow(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	now := seedRollup(t, s)

	if _, err := s.RollupModelStats(ctx, now); err != nil {
		t.Fatalf("first RollupModelStats() error = %v", err)
	}
	// A row for an already-folded (day, version) can only appear through a
	// direct write; the fold must still add, not overwrite.
	if err := s.ReplaceModelStats(ctx, "a", []ModelStatsDay{
		{Day: "2026-07-11", AppVersionCode: 20, Accepted: 3, Declined: 3, Unavailable: 3},
	}); err != nil {
		t.Fatalf("late row: %v", err)
	}
	if _, err := s.RollupModelStats(ctx, now); err != nil {
		t.Fatalf("second RollupModelStats() error = %v", err)
	}

	got := readRollup(t, s)
	want := rollupRow{Day: "2026-07-11", AppVersionCode: 20, Accepted: 7, Declined: 4, Unavailable: 3, InstallCount: 2}
	if len(got) != 3 || got[2] != want {
		t.Fatalf("rollup = %+v, want third row %+v", got, want)
	}
	if got := messagesArchived(t, s, "a"); got != 27 {
		t.Errorf("messages_archived(a) = %d, want 27", got)
	}
}

func TestRollupModelStatsWithNothingToFold(t *testing.T) {
	s := newTestStore(t)

	res, err := s.RollupModelStats(context.Background(), time.Date(2026, 10, 10, 0, 0, 0, 0, time.UTC))
	if err != nil || res != (RollupResult{}) {
		t.Fatalf("RollupModelStats() = %+v, %v; want zero, nil", res, err)
	}
}
