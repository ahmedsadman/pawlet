package devseed

import (
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
	if sum.Installs < 50 || sum.InstallDays == 0 || sum.Usage == 0 || sum.Counters == 0 {
		t.Fatalf("summary = %+v", sum)
	}
	if sum.From != "2026-07-12" || sum.To != "2026-10-09" {
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
