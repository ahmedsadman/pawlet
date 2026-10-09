// Package store persists anonymous install records and usage counters in SQLite.
package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"time"

	// Pure-Go SQLite driver, registered under the name "sqlite". Chosen over
	// mattn/go-sqlite3 so the image can build with CGO_ENABLED=0.
	_ "modernc.org/sqlite"
)

// ErrNotFound reports an absent install record.
var ErrNotFound = errors.New("store: not found")

// ErrSchemaTooOld reports a database that has not yet been migrated to the
// version this binary reads. Only pawletd migrates; readers wait for it.
var ErrSchemaTooOld = errors.New("store: database schema is older than this binary needs")

// Install is one anonymous install, keyed by the SHA-256 of its install ID.
type Install struct {
	IDHash    string
	FirstSeen time.Time
	LastSeen  time.Time
	Banned    bool
	BanReason string
	Meta      InstallMeta
}

// InstallMeta is what the install's latest Play Integrity verdict said about
// it. A zero field is stored as NULL: the verdict did not carry it.
type InstallMeta struct {
	AppVersionCode int64
	// DeviceTier is "STRONG" or "DEVICE". Policy already requires device
	// integrity, so a basic-only install never gets this far.
	DeviceTier string
	// Licensing is Play's appLicensingVerdict: LICENSED, UNLICENSED or
	// UNEVALUATED.
	Licensing  string
	SDKVersion int64
}

// dayLayout is the UTC day key; same format as usage.day.
const dayLayout = "2006-01-02"

// Store owns two pools over one SQLite file: writes are pinned to a single
// connection so they queue instead of returning SQLITE_BUSY, while WAL mode
// lets any number of readers proceed concurrently and unblocked.
type Store struct {
	write *sql.DB
	read  *sql.DB
}

const dsnParams = "?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)" +
	"&_pragma=synchronous(NORMAL)&_pragma=foreign_keys(on)"

// Open prepares the database file and both pools, migrating the schema to
// the newest version this binary knows. Only pawletd calls this.
func Open(path string) (*Store, error) {
	s, err := openPools(path)
	if err != nil {
		return nil, err
	}
	if err := migrate(context.Background(), s.write); err != nil {
		_ = s.Close()
		return nil, err
	}
	return s, nil
}

// OpenExisting opens a database that another process owns and migrates. It
// never changes the schema, and refuses a missing file or one older than
// SchemaVersion so a reader cannot query tables that do not exist yet.
func OpenExisting(path string) (*Store, error) {
	if _, err := os.Stat(path); err != nil {
		return nil, fmt.Errorf("open existing database: %w", err)
	}
	s, err := openPools(path)
	if err != nil {
		return nil, err
	}
	var version int
	if err := s.read.QueryRowContext(context.Background(), "PRAGMA user_version").Scan(&version); err != nil {
		_ = s.Close()
		return nil, fmt.Errorf("read schema version: %w", err)
	}
	if version < SchemaVersion() {
		_ = s.Close()
		return nil, fmt.Errorf("%w: have %d, need %d", ErrSchemaTooOld, version, SchemaVersion())
	}
	return s, nil
}

func openPools(path string) (*Store, error) {
	// Write pool uses IMMEDIATE transactions so concurrent openers racing to
	// apply the same migration (e.g., during an overlapping deploy) take the
	// write lock before reading user_version, preventing both from trying a
	// non-idempotent migration like ALTER TABLE ADD COLUMN.
	writeDSN := "file:" + path + dsnParams + "&_txlock=immediate"
	readDSN := "file:" + path + dsnParams

	write, err := sql.Open("sqlite", writeDSN)
	if err != nil {
		return nil, fmt.Errorf("open write pool: %w", err)
	}
	write.SetMaxOpenConns(1)

	read, err := sql.Open("sqlite", readDSN)
	if err != nil {
		_ = write.Close()
		return nil, fmt.Errorf("open read pool: %w", err)
	}
	read.SetMaxOpenConns(8)
	return &Store{write: write, read: read}, nil
}

// Close releases both pools.
func (s *Store) Close() error {
	return errors.Join(s.read.Close(), s.write.Close())
}

// TouchInstall inserts the install or refreshes its last_seen and verdict
// metadata, and records today (UTC) as one of its session days. Both writes
// share a transaction so the two tables never disagree.
func (s *Store) TouchInstall(ctx context.Context, idHash string, now time.Time, meta InstallMeta) error {
	tx, err := s.write.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin touch install: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	const upsertInstall = `INSERT INTO installs
	    (id_hash, first_seen, last_seen, app_version_code, device_tier, licensing, sdk_version)
	  VALUES (?, ?, ?, ?, ?, ?, ?)
	  ON CONFLICT(id_hash) DO UPDATE SET
	    last_seen        = excluded.last_seen,
	    app_version_code = excluded.app_version_code,
	    device_tier      = excluded.device_tier,
	    licensing        = excluded.licensing,
	    sdk_version      = excluded.sdk_version`
	version := nullInt(meta.AppVersionCode)
	if _, err := tx.ExecContext(ctx, upsertInstall,
		idHash, now.Unix(), now.Unix(),
		version, nullString(meta.DeviceTier), nullString(meta.Licensing), nullInt(meta.SDKVersion),
	); err != nil {
		return fmt.Errorf("touch install: %w", err)
	}

	const upsertDay = `INSERT INTO install_days (id_hash, day, app_version_code)
	  VALUES (?, ?, ?)
	  ON CONFLICT(id_hash, day) DO UPDATE SET app_version_code = excluded.app_version_code`
	if _, err := tx.ExecContext(ctx, upsertDay, idHash, now.UTC().Format(dayLayout), version); err != nil {
		return fmt.Errorf("record install day: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit touch install: %w", err)
	}
	return nil
}

func nullInt(v int64) sql.NullInt64 { return sql.NullInt64{Int64: v, Valid: v != 0} }

func nullString(v string) sql.NullString { return sql.NullString{String: v, Valid: v != ""} }

// installColumns is the column list scanInstall expects, in order.
const installColumns = `id_hash, first_seen, last_seen, banned, ban_reason,
	app_version_code, device_tier, licensing, sdk_version`

type rowScanner interface {
	Scan(dest ...any) error
}

func scanInstall(sc rowScanner) (Install, error) {
	var (
		rec               Install
		firstSec, lastSec int64
		banned            int
		version, sdk      sql.NullInt64
		tier, licensing   sql.NullString
	)
	if err := sc.Scan(
		&rec.IDHash, &firstSec, &lastSec, &banned, &rec.BanReason,
		&version, &tier, &licensing, &sdk,
	); err != nil {
		return Install{}, err
	}
	rec.FirstSeen = time.Unix(firstSec, 0)
	rec.LastSeen = time.Unix(lastSec, 0)
	rec.Banned = banned != 0
	rec.Meta = InstallMeta{
		AppVersionCode: version.Int64,
		DeviceTier:     tier.String,
		Licensing:      licensing.String,
		SDKVersion:     sdk.Int64,
	}
	return rec, nil
}

// Install reads one record, returning ErrNotFound when absent.
func (s *Store) Install(ctx context.Context, idHash string) (Install, error) {
	const q = `SELECT ` + installColumns + ` FROM installs WHERE id_hash = ?`
	rec, err := scanInstall(s.read.QueryRowContext(ctx, q, idHash))
	if errors.Is(err, sql.ErrNoRows) {
		return Install{}, ErrNotFound
	}
	if err != nil {
		return Install{}, fmt.Errorf("read install: %w", err)
	}
	return rec, nil
}

// InstallDays lists the UTC days on which the install minted a session,
// oldest first.
func (s *Store) InstallDays(ctx context.Context, idHash string) ([]string, error) {
	const q = `SELECT day FROM install_days WHERE id_hash = ? ORDER BY day`
	rows, err := s.read.QueryContext(ctx, q, idHash)
	if err != nil {
		return nil, fmt.Errorf("query install days: %w", err)
	}
	defer func() { _ = rows.Close() }()

	var days []string
	for rows.Next() {
		var day string
		if err := rows.Scan(&day); err != nil {
			return nil, fmt.Errorf("scan install day: %w", err)
		}
		days = append(days, day)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate install days: %w", err)
	}
	return days, nil
}

// Ban marks an install as refused for all future requests.
func (s *Store) Ban(ctx context.Context, idHash, reason string) error {
	const q = `UPDATE installs SET banned = 1, ban_reason = ? WHERE id_hash = ?`
	if _, err := s.write.ExecContext(ctx, q, reason, idHash); err != nil {
		return fmt.Errorf("ban install: %w", err)
	}
	return nil
}

// Unban lifts a ban and clears its reason.
func (s *Store) Unban(ctx context.Context, idHash string) error {
	const q = `UPDATE installs SET banned = 0, ban_reason = '' WHERE id_hash = ?`
	if _, err := s.write.ExecContext(ctx, q, idHash); err != nil {
		return fmt.Errorf("unban install: %w", err)
	}
	return nil
}

// Ping reports whether the database is queryable. It runs a trivial read
// against the schema rather than only dialling the pool: a pooled connection
// can look healthy while the underlying file is unreadable.
func (s *Store) Ping(ctx context.Context) error {
	var one int
	err := s.read.QueryRowContext(ctx, `SELECT 1 FROM sqlite_schema LIMIT 1`).Scan(&one)
	if err != nil {
		return fmt.Errorf("ping database: %w", err)
	}
	return nil
}
