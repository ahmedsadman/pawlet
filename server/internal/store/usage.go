package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

// LLMMessageRetentionDays is how many UTC days a counted message key is
// remembered. A retry of a key older than this counts as a new call. The
// app's own retries end within about a day; the margin covers a user tapping
// Retry on a failed message much later.
const LLMMessageRetentionDays = 30

// UsageDelta is an increment to one install's quota counters for one UTC day:
// admitted attempts and the tokens they spent. Distinct calls are counted by
// CountLLMMessage instead.
type UsageDelta struct {
	IDHash   string
	Day      string
	Attempts int64
	Tokens   int64
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

	const q = `INSERT INTO usage (id_hash, day, attempts, tokens)
	           VALUES (?, ?, ?, ?)
	           ON CONFLICT(id_hash, day) DO UPDATE SET
	             attempts = attempts + excluded.attempts,
	             tokens   = tokens   + excluded.tokens`
	stmt, err := tx.PrepareContext(ctx, q)
	if err != nil {
		return fmt.Errorf("prepare usage upsert: %w", err)
	}
	defer func() { _ = stmt.Close() }()

	for _, d := range deltas {
		if _, err := stmt.ExecContext(ctx, d.IDHash, d.Day, d.Attempts, d.Tokens); err != nil {
			return fmt.Errorf("upsert usage for %s on %s: %w", d.IDHash, d.Day, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit usage tx: %w", err)
	}
	return nil
}

// CountLLMMessage counts one call in usage.calls for the message with key,
// unless the install already had that key counted, and reports whether it
// counted. The call is credited to day, the day the key was first seen. An
// empty key (an app too old to send one) counts every time.
func (s *Store) CountLLMMessage(ctx context.Context, idHash, day, key string) (bool, error) {
	tx, err := s.write.BeginTx(ctx, nil)
	if err != nil {
		return false, fmt.Errorf("begin llm message tx: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	if key != "" {
		res, err := tx.ExecContext(ctx,
			`INSERT INTO llm_messages (id_hash, message_key, day) VALUES (?, ?, ?)
			 ON CONFLICT(id_hash, message_key) DO NOTHING`,
			idHash, key, day)
		if err != nil {
			return false, fmt.Errorf("record llm message: %w", err)
		}
		n, err := res.RowsAffected()
		if err != nil {
			return false, fmt.Errorf("record llm message: %w", err)
		}
		if n == 0 {
			return false, nil
		}
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO usage (id_hash, day, calls) VALUES (?, ?, 1)
		 ON CONFLICT(id_hash, day) DO UPDATE SET calls = calls + 1`,
		idHash, day); err != nil {
		return false, fmt.Errorf("count llm call: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return false, fmt.Errorf("commit llm message tx: %w", err)
	}
	return true, nil
}

// PruneLLMMessages forgets message keys first seen before day and returns how
// many it dropped.
func (s *Store) PruneLLMMessages(ctx context.Context, before string) (int64, error) {
	res, err := s.write.ExecContext(ctx, `DELETE FROM llm_messages WHERE day < ?`, before)
	if err != nil {
		return 0, fmt.Errorf("prune llm messages: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("prune llm messages: %w", err)
	}
	return n, nil
}

// Usage reads the persisted counters for one install and day. An absent row
// reads as zero, which is the same thing as never having called.
func (s *Store) Usage(ctx context.Context, idHash, day string) (UsageRow, error) {
	u := UsageRow{IDHash: idHash, Day: day}
	const q = `SELECT calls, attempts, tokens FROM usage WHERE id_hash = ? AND day = ?`
	err := s.read.QueryRowContext(ctx, q, idHash, day).Scan(&u.Calls, &u.Attempts, &u.Tokens)
	if errors.Is(err, sql.ErrNoRows) {
		return u, nil
	}
	if err != nil {
		return UsageRow{}, fmt.Errorf("read usage: %w", err)
	}
	return u, nil
}

// UsageForDay reads admitted attempts for all installs on the given UTC day:
// what the quota has charged.
func (s *Store) UsageForDay(ctx context.Context, day string) (map[string]int64, error) {
	const q = `SELECT id_hash, attempts FROM usage WHERE day = ?`
	rows, err := s.read.QueryContext(ctx, q, day)
	if err != nil {
		return nil, fmt.Errorf("query usage for day: %w", err)
	}
	defer func() { _ = rows.Close() }()

	result := make(map[string]int64)
	for rows.Next() {
		var idHash string
		var attempts int64
		if err := rows.Scan(&idHash, &attempts); err != nil {
			return nil, fmt.Errorf("scan usage row: %w", err)
		}
		result[idHash] = attempts
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate usage rows: %w", err)
	}
	return result, nil
}
