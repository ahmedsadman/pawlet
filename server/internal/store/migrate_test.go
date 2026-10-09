package store

import (
	"context"
	"database/sql"
	"errors"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
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
	if rec.Meta != (InstallMeta{}) {
		t.Errorf("legacy Meta = %+v, want zero (NULL columns)", rec.Meta)
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

func TestOpenConcurrentAppliesMigrationOnce(t *testing.T) {
	// Mutates package-level migrations; must not run in parallel.
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "concurrent.db")

	// Create a database at the current schema version first.
	s1, err := Open(path)
	if err != nil {
		t.Fatalf("first Open() error = %v", err)
	}
	if err := s1.Close(); err != nil {
		t.Fatalf("Close() error = %v", err)
	}

	// Inject a non-idempotent migration at the next version (ALTER TABLE ADD
	// COLUMN would fail if applied twice). Without the re-check fix, concurrent
	// openers would both try to apply it and one would fail.
	old := migrations
	migrations = append(append([]string(nil), migrations...), "ALTER TABLE installs ADD COLUMN probe TEXT;")
	t.Cleanup(func() { migrations = old })

	// Open from 4 goroutines concurrently; all must succeed.
	const n = 4
	var wg sync.WaitGroup
	errs := make([]error, n)
	stores := make([]*Store, n)
	wg.Add(n)
	for i := 0; i < n; i++ {
		go func(i int) {
			defer wg.Done()
			s, err := Open(path)
			if err != nil {
				errs[i] = err
				return
			}
			stores[i] = s
		}(i)
	}
	wg.Wait()

	for i, err := range errs {
		if err != nil {
			t.Errorf("goroutine %d Open() error = %v", i, err)
		}
	}
	for i, s := range stores {
		if s != nil {
			if got := userVersion(t, s.read); got != SchemaVersion() {
				t.Errorf("goroutine %d user_version = %d, want %d", i, got, SchemaVersion())
			}
			_ = s.Close()
		}
	}

	// Verify the probe column exists. The migration ran exactly once because all
	// four Opens succeeded — a second ADD COLUMN would have errored.
	raw, err := sql.Open("sqlite", "file:"+path)
	if err != nil {
		t.Fatalf("open raw: %v", err)
	}
	defer func() { _ = raw.Close() }()
	var probe sql.NullString
	err = raw.QueryRowContext(ctx, "SELECT probe FROM installs LIMIT 1").Scan(&probe)
	// Empty table is fine; we just want to verify the column exists.
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		t.Errorf("probe column missing or query failed: %v", err)
	}
}

func TestOpenRollsBackFailedMigration(t *testing.T) {
	// Mutates package-level migrations; must not run in parallel.
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "rollback.db")

	// Create a database at the current schema version first.
	s1, err := Open(path)
	if err != nil {
		t.Fatalf("first Open() error = %v", err)
	}
	if err := s1.Close(); err != nil {
		t.Fatalf("Close() error = %v", err)
	}

	// Inject a failing migration: first statement succeeds, second fails
	// (duplicate column). The transaction should roll back, leaving user_version
	// at the previous version and no table `half`.
	old := migrations
	migrations = append(append([]string(nil), migrations...),
		"CREATE TABLE half (x INTEGER); ALTER TABLE installs ADD COLUMN banned INTEGER;")
	t.Cleanup(func() { migrations = old })

	s2, err := Open(path)
	if err == nil {
		_ = s2.Close()
		t.Fatal("Open() succeeded, want error from duplicate column")
	}
	// The injected migration brings SchemaVersion() to N, and Open() tries to
	// apply it, reporting "apply migration N" on failure.
	wantMsg := "apply migration " + strconv.Itoa(SchemaVersion())
	if !strings.Contains(err.Error(), wantMsg) {
		t.Errorf("error = %v, want it to contain %q", err, wantMsg)
	}

	// Verify user_version stayed at the previous version and table `half` does not exist.
	raw, err := sql.Open("sqlite", "file:"+path)
	if err != nil {
		t.Fatalf("open raw: %v", err)
	}
	defer func() { _ = raw.Close() }()

	// After rollback, user_version should be at the last successfully applied
	// migration (SchemaVersion()-1, since we injected one failing migration).
	want := SchemaVersion() - 1
	if got := userVersion(t, raw); got != want {
		t.Errorf("user_version = %d after rollback, want %d", got, want)
	}

	var count int
	err = raw.QueryRowContext(ctx,
		"SELECT COUNT(*) FROM sqlite_schema WHERE type='table' AND name='half'").Scan(&count)
	if err != nil {
		t.Fatalf("check for half table: %v", err)
	}
	if count != 0 {
		t.Errorf("table half exists after rollback, want it rolled back")
	}
}
