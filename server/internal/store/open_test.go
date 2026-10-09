package store

import (
	"context"
	"database/sql"
	"errors"
	"path/filepath"
	"testing"
	"time"
)

func TestOpenExistingReadsMigratedDatabase(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "db")
	s, err := Open(path)
	if err != nil {
		t.Fatalf("Open() error = %v", err)
	}
	if err := s.TouchInstall(ctx, "h", time.Unix(1_700_000_000, 0), InstallMeta{}); err != nil {
		t.Fatalf("TouchInstall() error = %v", err)
	}
	_ = s.Close()

	r, err := OpenExisting(path)
	if err != nil {
		t.Fatalf("OpenExisting() error = %v", err)
	}
	t.Cleanup(func() { _ = r.Close() })
	if _, err := r.Install(ctx, "h"); err != nil {
		t.Fatalf("Install() error = %v", err)
	}
}

func TestOpenExistingRefusesOldSchemaWithoutMigrating(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "old.db")
	raw, err := sql.Open("sqlite", "file:"+path)
	if err != nil {
		t.Fatalf("open raw: %v", err)
	}
	if _, err := raw.ExecContext(ctx, legacySchema); err != nil {
		t.Fatalf("legacy schema: %v", err)
	}
	_ = raw.Close()

	_, err = OpenExisting(path)
	if !errors.Is(err, ErrSchemaTooOld) {
		t.Fatalf("err = %v, want ErrSchemaTooOld", err)
	}

	raw, _ = sql.Open("sqlite", "file:"+path)
	defer func() { _ = raw.Close() }()
	if got := userVersion(t, raw); got != 0 {
		t.Fatalf("user_version = %d, want 0 (OpenExisting must not migrate)", got)
	}
}

func TestOpenExistingMissingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "absent.db")
	if _, err := OpenExisting(path); err == nil {
		t.Fatal("OpenExisting() error = nil, want an error for a missing file")
	}
}

func TestUnbanClearsBanAndReason(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	if err := s.TouchInstall(ctx, "h", time.Unix(1_700_000_000, 0), InstallMeta{}); err != nil {
		t.Fatalf("TouchInstall() error = %v", err)
	}
	if err := s.Ban(ctx, "h", "abuse"); err != nil {
		t.Fatalf("Ban() error = %v", err)
	}
	if err := s.Unban(ctx, "h"); err != nil {
		t.Fatalf("Unban() error = %v", err)
	}
	rec, err := s.Install(ctx, "h")
	if err != nil {
		t.Fatalf("Install() error = %v", err)
	}
	if rec.Banned || rec.BanReason != "" {
		t.Fatalf("rec = %+v, want unbanned with empty reason", rec)
	}
}

func TestOpenExistingRefusesSchemaWithoutModelStats(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "v2.db")
	raw, err := sql.Open("sqlite", "file:"+path)
	if err != nil {
		t.Fatalf("open raw: %v", err)
	}
	for i, m := range migrations[:2] {
		if _, err := raw.ExecContext(ctx, m); err != nil {
			t.Fatalf("migration %d: %v", i+1, err)
		}
	}
	if _, err := raw.ExecContext(ctx, "PRAGMA user_version = 2"); err != nil {
		t.Fatalf("set user_version: %v", err)
	}
	_ = raw.Close()

	// pawlet-admin reads model_stats_daily, model_stats_rollup and
	// installs.messages_archived, which only exist from version 3.
	if _, err := OpenExisting(path); !errors.Is(err, ErrSchemaTooOld) {
		t.Fatalf("OpenExisting(v2) err = %v, want ErrSchemaTooOld", err)
	}
}
