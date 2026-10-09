package store

import (
	"context"
	"fmt"
)

// ModelStatsDay is one install's on-device model verdict counts for one UTC
// day under one app version.
type ModelStatsDay struct {
	Day            string
	AppVersionCode int64
	Accepted       int64
	Declined       int64
	Unavailable    int64
}

// ReplaceModelStats stores the install's counts for each (day, version) in
// one transaction. The app always sends whole-day totals, so an existing row
// is overwritten rather than added to: a resend is harmless.
func (s *Store) ReplaceModelStats(ctx context.Context, idHash string, days []ModelStatsDay) error {
	if len(days) == 0 {
		return nil
	}

	tx, err := s.write.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin model stats tx: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	const q = `INSERT INTO model_stats_daily
	             (id_hash, day, app_version_code, accepted, declined, unavailable)
	           VALUES (?, ?, ?, ?, ?, ?)
	           ON CONFLICT(id_hash, day, app_version_code) DO UPDATE SET
	             accepted    = excluded.accepted,
	             declined    = excluded.declined,
	             unavailable = excluded.unavailable`
	stmt, err := tx.PrepareContext(ctx, q)
	if err != nil {
		return fmt.Errorf("prepare model stats upsert: %w", err)
	}
	defer func() { _ = stmt.Close() }()

	for _, d := range days {
		if _, err := stmt.ExecContext(ctx,
			idHash, d.Day, d.AppVersionCode, d.Accepted, d.Declined, d.Unavailable); err != nil {
			return fmt.Errorf("upsert model stats for %s: %w", d.Day, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit model stats tx: %w", err)
	}
	return nil
}

// ModelStatsForInstall reads one install's per-day rows still inside the
// retention window, oldest day first, then by version.
func (s *Store) ModelStatsForInstall(ctx context.Context, idHash string) ([]ModelStatsDay, error) {
	const q = `SELECT day, app_version_code, accepted, declined, unavailable
	           FROM model_stats_daily WHERE id_hash = ? ORDER BY day, app_version_code`
	rows, err := s.read.QueryContext(ctx, q, idHash)
	if err != nil {
		return nil, fmt.Errorf("query model stats: %w", err)
	}
	defer func() { _ = rows.Close() }()

	var out []ModelStatsDay
	for rows.Next() {
		var d ModelStatsDay
		if err := rows.Scan(&d.Day, &d.AppVersionCode, &d.Accepted, &d.Declined, &d.Unavailable); err != nil {
			return nil, fmt.Errorf("scan model stats: %w", err)
		}
		out = append(out, d)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate model stats: %w", err)
	}
	return out, nil
}
