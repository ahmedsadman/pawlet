package store

import (
	"context"
	"fmt"
	"time"
)

// ModelStatsRetentionDays is how many UTC days of per-install model stats are
// kept. RollupModelStats folds anything older into model_stats_rollup.
const ModelStatsRetentionDays = 90

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

// RollupResult counts what one RollupModelStats run folded.
type RollupResult struct {
	Rows     int64 // model_stats_daily rows folded and deleted
	Messages int64 // accepted + declined + unavailable across those rows
}

// RollupModelStats folds every model_stats_daily row older than
// ModelStatsRetentionDays (relative to now's UTC day) into model_stats_rollup,
// adds each install's folded messages to installs.messages_archived, and
// deletes the folded rows, all in one transaction. A second run finds nothing
// to fold, so it is safe to repeat.
func (s *Store) RollupModelStats(ctx context.Context, now time.Time) (RollupResult, error) {
	cutoff := now.UTC().AddDate(0, 0, -ModelStatsRetentionDays).Format(dayLayout)

	tx, err := s.write.BeginTx(ctx, nil)
	if err != nil {
		return RollupResult{}, fmt.Errorf("begin rollup tx: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	var res RollupResult
	const count = `SELECT COUNT(*), COALESCE(SUM(accepted + declined + unavailable), 0)
	               FROM model_stats_daily WHERE day < ?`
	if err := tx.QueryRowContext(ctx, count, cutoff).Scan(&res.Rows, &res.Messages); err != nil {
		return RollupResult{}, fmt.Errorf("count rows to fold: %w", err)
	}
	if res.Rows == 0 {
		return RollupResult{}, nil
	}

	// The WHERE clause also keeps SQLite from parsing ON CONFLICT as a join
	// constraint of the SELECT.
	const fold = `INSERT INTO model_stats_rollup
	                (day, app_version_code, accepted, declined, unavailable, install_count)
	              SELECT day, app_version_code, SUM(accepted), SUM(declined), SUM(unavailable), COUNT(*)
	              FROM model_stats_daily WHERE day < ?
	              GROUP BY day, app_version_code
	              ON CONFLICT(day, app_version_code) DO UPDATE SET
	                accepted      = accepted      + excluded.accepted,
	                declined      = declined      + excluded.declined,
	                unavailable   = unavailable   + excluded.unavailable,
	                install_count = install_count + excluded.install_count`
	if _, err := tx.ExecContext(ctx, fold, cutoff); err != nil {
		return RollupResult{}, fmt.Errorf("fold into rollup: %w", err)
	}

	const archive = `UPDATE installs SET messages_archived = messages_archived + f.total
	                 FROM (SELECT id_hash, SUM(accepted + declined + unavailable) AS total
	                       FROM model_stats_daily WHERE day < ? GROUP BY id_hash) AS f
	                 WHERE installs.id_hash = f.id_hash`
	if _, err := tx.ExecContext(ctx, archive, cutoff); err != nil {
		return RollupResult{}, fmt.Errorf("archive install totals: %w", err)
	}

	if _, err := tx.ExecContext(ctx, `DELETE FROM model_stats_daily WHERE day < ?`, cutoff); err != nil {
		return RollupResult{}, fmt.Errorf("delete folded rows: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return RollupResult{}, fmt.Errorf("commit rollup tx: %w", err)
	}
	return res, nil
}
