package devseed

import (
	"context"
	"database/sql"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/ahmedsadman/pawlet/server/internal/store"
)

func TestSeedFillsEmptyDatabaseOnce(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dev.db")
	now := time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC)

	sum, err := Seed(path, now, 42)
	if err != nil {
		t.Fatalf("Seed() error = %v", err)
	}
	if sum.Installs < 50 || sum.InstallDays == 0 || sum.Usage == 0 || sum.Counters == 0 ||
		sum.ModelStats == 0 || sum.ModelStatsRollup == 0 {
		t.Fatalf("summary = %+v", sum)
	}
	if sum.From != "2026-06-12" || sum.To != "2026-10-09" {
		t.Fatalf("span = %s..%s", sum.From, sum.To)
	}

	if _, err := Seed(path, now, 42); !errors.Is(err, ErrNotEmpty) {
		t.Fatalf("second Seed() err = %v, want ErrNotEmpty", err)
	}

	st, err := store.OpenExisting(path)
	if err != nil {
		t.Fatalf("OpenExisting() error = %v", err)
	}
	defer func() { _ = st.Close() }()
	info, err := st.ServerInfo(t.Context())
	if err != nil || info[store.InfoImageTag] != "dev-seed" {
		t.Fatalf("server info = %v, %v", info, err)
	}
}

func TestSeedRefusesNonEmptyWithoutMigrating(t *testing.T) {
	path := filepath.Join(t.TempDir(), "legacy.db")
	now := time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC)

	// Create a database with an install and set schema version to 1 (legacy).
	st, err := store.Open(path)
	if err != nil {
		t.Fatalf("Open() error = %v", err)
	}
	if err := st.TouchInstall(t.Context(), "test-hash", now, store.InstallMeta{AppVersionCode: 14, DeviceTier: "DEVICE", Licensing: "LICENSED"}); err != nil {
		_ = st.Close()
		t.Fatalf("TouchInstall() error = %v", err)
	}
	_ = st.Close()

	db, err := sql.Open("sqlite", "file:"+path)
	if err != nil {
		t.Fatalf("sql.Open() error = %v", err)
	}
	defer func() { _ = db.Close() }()

	if _, err := db.Exec(`PRAGMA user_version = 1`); err != nil {
		t.Fatalf("set user_version error = %v", err)
	}

	// Verify it's at version 1.
	var version int
	if err := db.QueryRow(`PRAGMA user_version`).Scan(&version); err != nil || version != 1 {
		t.Fatalf("user_version = %d, %v; want 1", version, err)
	}

	// Seed should refuse without migrating.
	if _, err := Seed(path, now, 42); !errors.Is(err, ErrNotEmpty) {
		t.Fatalf("Seed() err = %v, want ErrNotEmpty", err)
	}

	// Verify schema version is still 1 (not migrated).
	if err := db.QueryRow(`PRAGMA user_version`).Scan(&version); err != nil || version != 1 {
		t.Fatalf("after Seed, user_version = %d, %v; want 1 (unchanged)", version, err)
	}
}

func TestSeedModelStats(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dev.db")
	now := time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC)
	if _, err := Seed(path, now, 42); err != nil {
		t.Fatalf("Seed() error = %v", err)
	}
	db, err := sql.Open("sqlite", "file:"+path)
	if err != nil {
		t.Fatalf("sql.Open() error = %v", err)
	}
	defer func() { _ = db.Close() }()
	ctx := context.Background()
	query := func(q string, dst ...any) {
		t.Helper()
		if err := db.QueryRowContext(ctx, q).Scan(dst...); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}

	// Rows older than the 90-day window were folded, none left behind.
	var stale, rollupDays int
	var newestRollup string
	query(`SELECT COUNT(*) FROM model_stats_daily WHERE day < '2026-07-11'`, &stale)
	query(`SELECT COUNT(DISTINCT day), MAX(day) FROM model_stats_rollup`, &rollupDays, &newestRollup)
	if stale != 0 {
		t.Errorf("%d model_stats_daily rows older than the window, want 0", stale)
	}
	if rollupDays < 20 || newestRollup != "2026-07-10" {
		t.Errorf("rollup covers %d days ending %s, want 20+ ending 2026-07-10", rollupDays, newestRollup)
	}

	// Every folded message is archived against its install.
	var archived, folded int64
	query(`SELECT SUM(messages_archived) FROM installs`, &archived)
	query(`SELECT SUM(accepted + declined + unavailable) FROM model_stats_rollup`, &folded)
	if archived == 0 || archived != folded {
		t.Errorf("messages_archived total = %d, rollup total = %d; want equal and non-zero", archived, folded)
	}

	// The on-device rate rises across the span.
	var early, late float64
	query(`SELECT 1.0 * SUM(accepted) / SUM(accepted + declined) FROM model_stats_rollup`, &early)
	query(`SELECT 1.0 * SUM(accepted) / SUM(accepted + declined) FROM model_stats_daily
	       WHERE day >= '2026-09-10'`, &late)
	if early < 0.65 || early > 0.75 || late < 0.78 || late > 0.88 || late <= early {
		t.Errorf("rate early = %.3f, late = %.3f; want ~0.70 rising to ~0.83", early, late)
	}

	// A small unavailable trickle, and one version switch.
	var unavailable, messages int64
	var versions int
	query(`SELECT SUM(unavailable), SUM(accepted + declined + unavailable) FROM model_stats_daily`,
		&unavailable, &messages)
	query(`SELECT COUNT(DISTINCT app_version_code) FROM model_stats_daily`, &versions)
	if unavailable == 0 || float64(unavailable) > 0.02*float64(messages) {
		t.Errorf("unavailable = %d of %d messages, want a small non-zero share", unavailable, messages)
	}
	if versions != 2 {
		t.Errorf("model stats carry %d app versions, want 2", versions)
	}
}
