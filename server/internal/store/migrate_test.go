package store

import (
	"context"
	"database/sql"
	"path/filepath"
	"strconv"
	"testing"
)

// legacySchema is the schema the pre-migrator binary applied on every start.
// Databases created by it have these tables and user_version 0.
const legacySchema = `
CREATE TABLE IF NOT EXISTS installs (
  id_hash    TEXT PRIMARY KEY,
  first_seen INTEGER NOT NULL,
  last_seen  INTEGER NOT NULL,
  banned     INTEGER NOT NULL DEFAULT 0,
  ban_reason TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS usage (
  id_hash TEXT NOT NULL,
  day     TEXT NOT NULL,
  calls   INTEGER NOT NULL DEFAULT 0,
  tokens  INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (id_hash, day)
);`

func userVersion(t *testing.T, db *sql.DB) int {
	t.Helper()
	var v int
	if err := db.QueryRowContext(context.Background(), "PRAGMA user_version").Scan(&v); err != nil {
		t.Fatalf("read user_version: %v", err)
	}
	return v
}

func TestOpenSetsSchemaVersion(t *testing.T) {
	s := newTestStore(t)

	if got := userVersion(t, s.read); got != SchemaVersion() {
		t.Fatalf("user_version = %d, want %d", got, SchemaVersion())
	}
}

func TestOpenUpgradesLegacyDatabaseKeepingData(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "legacy.db")

	raw, err := sql.Open("sqlite", "file:"+path)
	if err != nil {
		t.Fatalf("open raw: %v", err)
	}
	if _, err := raw.ExecContext(ctx, legacySchema); err != nil {
		t.Fatalf("apply legacy schema: %v", err)
	}
	if _, err := raw.ExecContext(ctx,
		`INSERT INTO installs (id_hash, first_seen, last_seen) VALUES ('legacy', 100, 200)`); err != nil {
		t.Fatalf("seed install: %v", err)
	}
	if _, err := raw.ExecContext(ctx,
		`INSERT INTO usage (id_hash, day, calls, tokens) VALUES ('legacy', '2026-10-01', 4, 90)`); err != nil {
		t.Fatalf("seed usage: %v", err)
	}
	if err := raw.Close(); err != nil {
		t.Fatalf("close raw: %v", err)
	}

	s, err := Open(path)
	if err != nil {
		t.Fatalf("Open() error = %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })

	if got := userVersion(t, s.read); got != SchemaVersion() {
		t.Fatalf("user_version = %d, want %d", got, SchemaVersion())
	}
	rec, err := s.Install(ctx, "legacy")
	if err != nil {
		t.Fatalf("Install() error = %v", err)
	}
	if rec.FirstSeen.Unix() != 100 || rec.LastSeen.Unix() != 200 {
		t.Errorf("rec = %+v, want first_seen 100, last_seen 200", rec)
	}
	calls, tokens, err := s.Usage(ctx, "legacy", "2026-10-01")
	if err != nil {
		t.Fatalf("Usage() error = %v", err)
	}
	if calls != 4 || tokens != 90 {
		t.Errorf("calls, tokens = %d, %d; want 4, 90", calls, tokens)
	}
}

func TestOpenTwiceIsIdempotent(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "twice.db")

	s1, err := Open(path)
	if err != nil {
		t.Fatalf("first Open() error = %v", err)
	}
	if err := s1.AddUsage(ctx, []UsageDelta{{IDHash: "a", Day: "2026-10-02", Calls: 3}}); err != nil {
		t.Fatalf("AddUsage() error = %v", err)
	}
	if err := s1.Close(); err != nil {
		t.Fatalf("Close() error = %v", err)
	}

	s2, err := Open(path)
	if err != nil {
		t.Fatalf("second Open() error = %v", err)
	}
	t.Cleanup(func() { _ = s2.Close() })

	calls, _, err := s2.Usage(ctx, "a", "2026-10-02")
	if err != nil {
		t.Fatalf("Usage() error = %v", err)
	}
	if calls != 3 {
		t.Fatalf("calls = %d, want 3", calls)
	}
	if got := userVersion(t, s2.read); got != SchemaVersion() {
		t.Fatalf("user_version = %d, want %d", got, SchemaVersion())
	}
}

func TestOpenAcceptsNewerSchema(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "newer.db")

	s1, err := Open(path)
	if err != nil {
		t.Fatalf("first Open() error = %v", err)
	}
	newer := SchemaVersion() + 5
	if _, err := s1.write.ExecContext(ctx, "PRAGMA user_version = "+strconv.Itoa(newer)); err != nil {
		t.Fatalf("bump user_version: %v", err)
	}
	if err := s1.Close(); err != nil {
		t.Fatalf("Close() error = %v", err)
	}

	// An older binary must still start against a newer database, otherwise
	// rolling back by image tag would brick the service.
	s2, err := Open(path)
	if err != nil {
		t.Fatalf("Open() on newer schema error = %v", err)
	}
	t.Cleanup(func() { _ = s2.Close() })

	if got := userVersion(t, s2.read); got != newer {
		t.Fatalf("user_version = %d, want untouched %d", got, newer)
	}
}
