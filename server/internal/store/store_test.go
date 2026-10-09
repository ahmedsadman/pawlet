package store

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"testing"
	"time"
)

func newTestStore(t *testing.T) *Store {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("Open() error = %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func TestTouchInstallCreatesThenUpdates(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	first := time.Unix(1_700_000_000, 0)

	if err := s.TouchInstall(ctx, "hash-a", first, InstallMeta{}); err != nil {
		t.Fatalf("TouchInstall() error = %v", err)
	}
	later := first.Add(time.Hour)
	if err := s.TouchInstall(ctx, "hash-a", later, InstallMeta{}); err != nil {
		t.Fatalf("second TouchInstall() error = %v", err)
	}

	rec, err := s.Install(ctx, "hash-a")
	if err != nil {
		t.Fatalf("Install() error = %v", err)
	}
	if !rec.FirstSeen.Equal(first) {
		t.Errorf("FirstSeen = %v, want %v", rec.FirstSeen, first)
	}
	if !rec.LastSeen.Equal(later) {
		t.Errorf("LastSeen = %v, want %v", rec.LastSeen, later)
	}
	if rec.Banned {
		t.Error("Banned = true, want false")
	}
}

func TestInstallMissingReturnsNotFound(t *testing.T) {
	s := newTestStore(t)

	_, err := s.Install(context.Background(), "absent")
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("err = %v, want ErrNotFound", err)
	}
}

func TestBanIsVisibleToInstall(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	if err := s.TouchInstall(ctx, "hash-b", time.Unix(1_700_000_000, 0), InstallMeta{}); err != nil {
		t.Fatalf("TouchInstall() error = %v", err)
	}

	if err := s.Ban(ctx, "hash-b", "abuse"); err != nil {
		t.Fatalf("Ban() error = %v", err)
	}

	rec, err := s.Install(ctx, "hash-b")
	if err != nil {
		t.Fatalf("Install() error = %v", err)
	}
	if !rec.Banned || rec.BanReason != "abuse" {
		t.Errorf("rec = %+v, want banned with reason abuse", rec)
	}
}

func TestConcurrentWritesSerialiseWithoutError(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	now := time.Unix(1_700_000_000, 0)

	// Distinct hashes so the run proves every write landed, not merely that
	// repeated upserts of one row avoided SQLITE_BUSY.
	const writers = 10
	errs := make(chan error, writers)
	for i := 0; i < writers; i++ {
		go func(i int) {
			errs <- s.TouchInstall(ctx, fmt.Sprintf("hash-c-%d", i), now, InstallMeta{})
		}(i)
	}
	for i := 0; i < writers; i++ {
		if err := <-errs; err != nil {
			t.Fatalf("concurrent TouchInstall() error = %v", err)
		}
	}

	for i := 0; i < writers; i++ {
		if _, err := s.Install(ctx, fmt.Sprintf("hash-c-%d", i)); err != nil {
			t.Errorf("install %d missing after concurrent writes: %v", i, err)
		}
	}
}

func TestTouchInstallStoresMeta(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	meta := InstallMeta{AppVersionCode: 18, DeviceTier: "STRONG", Licensing: "LICENSED", SDKVersion: 34}

	if err := s.TouchInstall(ctx, "hash-m", time.Unix(1_700_000_000, 0), meta); err != nil {
		t.Fatalf("TouchInstall() error = %v", err)
	}

	rec, err := s.Install(ctx, "hash-m")
	if err != nil {
		t.Fatalf("Install() error = %v", err)
	}
	if rec.Meta != meta {
		t.Fatalf("Meta = %+v, want %+v", rec.Meta, meta)
	}
}

func TestTouchInstallOverwritesMetaWithNull(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	now := time.Unix(1_700_000_000, 0)

	full := InstallMeta{AppVersionCode: 18, DeviceTier: "DEVICE", Licensing: "LICENSED", SDKVersion: 34}
	if err := s.TouchInstall(ctx, "hash-n", now, full); err != nil {
		t.Fatalf("TouchInstall() error = %v", err)
	}
	// The latest verdict is the truth: a field it omits is unknown now.
	if err := s.TouchInstall(ctx, "hash-n", now.Add(time.Hour), InstallMeta{}); err != nil {
		t.Fatalf("second TouchInstall() error = %v", err)
	}

	var versionNull, tierNull, licensingNull, sdkNull bool
	err := s.read.QueryRowContext(ctx,
		`SELECT app_version_code IS NULL, device_tier IS NULL, licensing IS NULL, sdk_version IS NULL
		 FROM installs WHERE id_hash = ?`, "hash-n").
		Scan(&versionNull, &tierNull, &licensingNull, &sdkNull)
	if err != nil {
		t.Fatalf("read meta columns: %v", err)
	}
	if !versionNull || !tierNull || !licensingNull || !sdkNull {
		t.Fatalf("NULLs = %v %v %v %v, want all true", versionNull, tierNull, licensingNull, sdkNull)
	}
}

func TestTouchInstallRecordsSessionDays(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	day1 := time.Date(2026, 10, 8, 9, 0, 0, 0, time.UTC)
	day2 := time.Date(2026, 10, 9, 9, 0, 0, 0, time.UTC)

	if err := s.TouchInstall(ctx, "hash-d", day1, InstallMeta{AppVersionCode: 17}); err != nil {
		t.Fatalf("TouchInstall() error = %v", err)
	}
	if err := s.TouchInstall(ctx, "hash-d", day1.Add(3*time.Hour), InstallMeta{AppVersionCode: 18}); err != nil {
		t.Fatalf("TouchInstall() error = %v", err)
	}
	if err := s.TouchInstall(ctx, "hash-d", day2, InstallMeta{AppVersionCode: 18}); err != nil {
		t.Fatalf("TouchInstall() error = %v", err)
	}

	days, err := s.InstallDays(ctx, "hash-d")
	if err != nil {
		t.Fatalf("InstallDays() error = %v", err)
	}
	if len(days) != 2 || days[0] != "2026-10-08" || days[1] != "2026-10-09" {
		t.Fatalf("days = %v, want [2026-10-08 2026-10-09]", days)
	}

	// The day row keeps the latest version seen that day.
	var version int64
	err = s.read.QueryRowContext(ctx,
		`SELECT app_version_code FROM install_days WHERE id_hash = ? AND day = ?`,
		"hash-d", "2026-10-08").Scan(&version)
	if err != nil {
		t.Fatalf("read day version: %v", err)
	}
	if version != 18 {
		t.Fatalf("day version = %d, want 18", version)
	}
}

func TestTouchInstallSessionDayIsUTC(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	// 02:00 in Dhaka (UTC+6) is 20:00 the previous day in UTC.
	dhaka := time.FixedZone("BST", 6*60*60)
	now := time.Date(2026, 10, 9, 2, 0, 0, 0, dhaka)

	if err := s.TouchInstall(ctx, "hash-u", now, InstallMeta{}); err != nil {
		t.Fatalf("TouchInstall() error = %v", err)
	}

	days, err := s.InstallDays(ctx, "hash-u")
	if err != nil {
		t.Fatalf("InstallDays() error = %v", err)
	}
	if len(days) != 1 || days[0] != "2026-10-08" {
		t.Fatalf("days = %v, want [2026-10-08]", days)
	}
}

func TestInstallDaysUnknownIsEmpty(t *testing.T) {
	s := newTestStore(t)

	days, err := s.InstallDays(context.Background(), "nobody")
	if err != nil {
		t.Fatalf("InstallDays() error = %v", err)
	}
	if len(days) != 0 {
		t.Fatalf("days = %v, want empty", days)
	}
}
