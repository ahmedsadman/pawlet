// Package store persists anonymous install records and usage counters in SQLite.
package store

import (
	"context"
	"database/sql"
	_ "embed"
	"errors"
	"fmt"
	"time"

	_ "modernc.org/sqlite"
)

//go:embed schema.sql
var schema string

// ErrNotFound reports an absent install record.
var ErrNotFound = errors.New("store: not found")

// Install is one anonymous install, keyed by the SHA-256 of its install ID.
type Install struct {
	IDHash    string
	FirstSeen time.Time
	LastSeen  time.Time
	Banned    bool
	BanReason string
}

// Store owns two pools over one SQLite file: writes are pinned to a single
// connection so they queue instead of returning SQLITE_BUSY, while WAL mode
// lets any number of readers proceed concurrently and unblocked.
type Store struct {
	write *sql.DB
	read  *sql.DB
}

const dsnParams = "?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)" +
	"&_pragma=synchronous(NORMAL)&_pragma=foreign_keys(on)"

// Open prepares the database file and both pools.
func Open(path string) (*Store, error) {
	dsn := "file:" + path + dsnParams

	write, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open write pool: %w", err)
	}
	write.SetMaxOpenConns(1)

	if _, err := write.ExecContext(context.Background(), schema); err != nil {
		_ = write.Close()
		return nil, fmt.Errorf("apply schema: %w", err)
	}

	read, err := sql.Open("sqlite", dsn)
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

// TouchInstall inserts the install or refreshes its last_seen.
func (s *Store) TouchInstall(ctx context.Context, idHash string, now time.Time) error {
	const q = `INSERT INTO installs (id_hash, first_seen, last_seen)
	           VALUES (?, ?, ?)
	           ON CONFLICT(id_hash) DO UPDATE SET last_seen = excluded.last_seen`
	if _, err := s.write.ExecContext(ctx, q, idHash, now.Unix(), now.Unix()); err != nil {
		return fmt.Errorf("touch install: %w", err)
	}
	return nil
}

// Install reads one record, returning ErrNotFound when absent.
func (s *Store) Install(ctx context.Context, idHash string) (Install, error) {
	const q = `SELECT id_hash, first_seen, last_seen, banned, ban_reason
	           FROM installs WHERE id_hash = ?`
	var (
		rec               Install
		firstSec, lastSec int64
		banned            int
	)
	err := s.read.QueryRowContext(ctx, q, idHash).
		Scan(&rec.IDHash, &firstSec, &lastSec, &banned, &rec.BanReason)
	if errors.Is(err, sql.ErrNoRows) {
		return Install{}, ErrNotFound
	}
	if err != nil {
		return Install{}, fmt.Errorf("read install: %w", err)
	}
	rec.FirstSeen = time.Unix(firstSec, 0)
	rec.LastSeen = time.Unix(lastSec, 0)
	rec.Banned = banned != 0
	return rec, nil
}

// Ban marks an install as refused for all future requests.
func (s *Store) Ban(ctx context.Context, idHash, reason string) error {
	const q = `UPDATE installs SET banned = 1, ban_reason = ? WHERE id_hash = ?`
	if _, err := s.write.ExecContext(ctx, q, reason, idHash); err != nil {
		return fmt.Errorf("ban install: %w", err)
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
