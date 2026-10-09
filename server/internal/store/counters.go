package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

// CounterDelta is an increment to one daily aggregate counter.
type CounterDelta struct {
	Day    string
	Metric string
	Key    string
	Count  int64
}

// AddCounters applies every delta in a single transaction. Like AddUsage, it
// runs on the flush interval, never per request.
func (s *Store) AddCounters(ctx context.Context, deltas []CounterDelta) error {
	if len(deltas) == 0 {
		return nil
	}

	tx, err := s.write.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin counters tx: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	const q = `INSERT INTO counters_daily (day, metric, key, count)
	           VALUES (?, ?, ?, ?)
	           ON CONFLICT(day, metric, key) DO UPDATE SET count = count + excluded.count`
	stmt, err := tx.PrepareContext(ctx, q)
	if err != nil {
		return fmt.Errorf("prepare counters upsert: %w", err)
	}
	defer func() { _ = stmt.Close() }()

	for _, d := range deltas {
		if _, err := stmt.ExecContext(ctx, d.Day, d.Metric, d.Key, d.Count); err != nil {
			return fmt.Errorf("upsert counter %s/%s on %s: %w", d.Metric, d.Key, d.Day, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit counters tx: %w", err)
	}
	return nil
}

// Counter reads one counter. An absent row reads as zero.
func (s *Store) Counter(ctx context.Context, day, metric, key string) (int64, error) {
	const q = `SELECT count FROM counters_daily WHERE day = ? AND metric = ? AND key = ?`
	var n int64
	err := s.read.QueryRowContext(ctx, q, day, metric, key).Scan(&n)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("read counter: %w", err)
	}
	return n, nil
}
