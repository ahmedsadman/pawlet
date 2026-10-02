package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

// UsageDelta is an increment to one install's counters for one UTC day.
type UsageDelta struct {
	IDHash string
	Day    string
	Calls  int64
	Tokens int64
}

// AddUsage applies every delta in a single transaction. It is called on the
// flush interval rather than per request, so the write pool stays idle on the
// hot path.
func (s *Store) AddUsage(ctx context.Context, deltas []UsageDelta) error {
	if len(deltas) == 0 {
		return nil
	}

	tx, err := s.write.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin usage tx: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	const q = `INSERT INTO usage (id_hash, day, calls, tokens)
	           VALUES (?, ?, ?, ?)
	           ON CONFLICT(id_hash, day) DO UPDATE SET
	             calls  = calls  + excluded.calls,
	             tokens = tokens + excluded.tokens`
	stmt, err := tx.PrepareContext(ctx, q)
	if err != nil {
		return fmt.Errorf("prepare usage upsert: %w", err)
	}
	defer func() { _ = stmt.Close() }()

	for _, d := range deltas {
		if _, err := stmt.ExecContext(ctx, d.IDHash, d.Day, d.Calls, d.Tokens); err != nil {
			return fmt.Errorf("upsert usage for %s on %s: %w", d.IDHash, d.Day, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit usage tx: %w", err)
	}
	return nil
}

// Usage reads the persisted counters for one install and day. An absent row
// reads as zero, which is the same thing as never having called.
func (s *Store) Usage(ctx context.Context, idHash, day string) (calls, tokens int64, err error) {
	const q = `SELECT calls, tokens FROM usage WHERE id_hash = ? AND day = ?`
	err = s.read.QueryRowContext(ctx, q, idHash, day).Scan(&calls, &tokens)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, 0, nil
	}
	if err != nil {
		return 0, 0, fmt.Errorf("read usage: %w", err)
	}
	return calls, tokens, nil
}

// UsageForDay reads calls for all installs on the given UTC day.
func (s *Store) UsageForDay(ctx context.Context, day string) (map[string]int64, error) {
	const q = `SELECT id_hash, calls FROM usage WHERE day = ?`
	rows, err := s.read.QueryContext(ctx, q, day)
	if err != nil {
		return nil, fmt.Errorf("query usage for day: %w", err)
	}
	defer func() { _ = rows.Close() }()

	result := make(map[string]int64)
	for rows.Next() {
		var idHash string
		var calls int64
		if err := rows.Scan(&idHash, &calls); err != nil {
			return nil, fmt.Errorf("scan usage row: %w", err)
		}
		result[idHash] = calls
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate usage rows: %w", err)
	}
	return result, nil
}
