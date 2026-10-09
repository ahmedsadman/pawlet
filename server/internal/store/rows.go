package store

import (
	"context"
	"fmt"
	"time"
)

// UsageRow is one install's usage on one UTC day.
type UsageRow struct {
	IDHash string
	Day    string
	Calls  int64
	Tokens int64
}

// DayRow is one install's session day and the version it attested with.
type DayRow struct {
	IDHash         string
	Day            string
	AppVersionCode int64
}

// CounterRow is one daily aggregate counter.
type CounterRow struct {
	Day    string
	Metric string
	Key    string
	Count  int64
}

// EarliestDays names the first UTC day each history source has data for; ""
// when the source is empty.
type EarliestDays struct {
	Usage       string
	InstallDays string
	Counters    string
	FirstSeen   string
}

// Any is the earliest day across every source, or "" for an empty database.
func (e EarliestDays) Any() string {
	earliest := ""
	for _, d := range []string{e.Usage, e.InstallDays, e.Counters, e.FirstSeen} {
		if d != "" && (earliest == "" || d < earliest) {
			earliest = d
		}
	}
	return earliest
}

// AllInstalls reads every install, oldest first. The dashboard works on the
// whole set in memory; at this service's scale that is hundreds of rows.
func (s *Store) AllInstalls(ctx context.Context) ([]Install, error) {
	const q = `SELECT ` + installColumns + ` FROM installs ORDER BY first_seen, id_hash`
	rows, err := s.read.QueryContext(ctx, q)
	if err != nil {
		return nil, fmt.Errorf("query installs: %w", err)
	}
	defer func() { _ = rows.Close() }()

	var out []Install
	for rows.Next() {
		rec, err := scanInstall(rows)
		if err != nil {
			return nil, fmt.Errorf("scan install: %w", err)
		}
		out = append(out, rec)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate installs: %w", err)
	}
	return out, nil
}

// AllUsage reads every usage row, oldest day first.
func (s *Store) AllUsage(ctx context.Context) ([]UsageRow, error) {
	return s.queryUsage(ctx, `SELECT id_hash, day, calls, tokens FROM usage ORDER BY day, id_hash`)
}

// UsageBetween reads usage rows for days from..to inclusive.
func (s *Store) UsageBetween(ctx context.Context, from, to string) ([]UsageRow, error) {
	return s.queryUsage(ctx,
		`SELECT id_hash, day, calls, tokens FROM usage WHERE day BETWEEN ? AND ? ORDER BY day, id_hash`,
		from, to)
}

// UsageForInstall reads one install's usage rows, oldest first.
func (s *Store) UsageForInstall(ctx context.Context, idHash string) ([]UsageRow, error) {
	return s.queryUsage(ctx,
		`SELECT id_hash, day, calls, tokens FROM usage WHERE id_hash = ? ORDER BY day`, idHash)
}

func (s *Store) queryUsage(ctx context.Context, q string, args ...any) ([]UsageRow, error) {
	rows, err := s.read.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, fmt.Errorf("query usage: %w", err)
	}
	defer func() { _ = rows.Close() }()

	var out []UsageRow
	for rows.Next() {
		var u UsageRow
		if err := rows.Scan(&u.IDHash, &u.Day, &u.Calls, &u.Tokens); err != nil {
			return nil, fmt.Errorf("scan usage: %w", err)
		}
		out = append(out, u)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate usage: %w", err)
	}
	return out, nil
}

// InstallDaysBetween reads session days from..to inclusive. An unknown
// version reads as 0.
func (s *Store) InstallDaysBetween(ctx context.Context, from, to string) ([]DayRow, error) {
	const q = `SELECT id_hash, day, COALESCE(app_version_code, 0) FROM install_days
	           WHERE day BETWEEN ? AND ? ORDER BY day, id_hash`
	rows, err := s.read.QueryContext(ctx, q, from, to)
	if err != nil {
		return nil, fmt.Errorf("query install days: %w", err)
	}
	defer func() { _ = rows.Close() }()

	var out []DayRow
	for rows.Next() {
		var d DayRow
		if err := rows.Scan(&d.IDHash, &d.Day, &d.AppVersionCode); err != nil {
			return nil, fmt.Errorf("scan install day: %w", err)
		}
		out = append(out, d)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate install days: %w", err)
	}
	return out, nil
}

// CountersBetween reads daily counters from..to inclusive.
func (s *Store) CountersBetween(ctx context.Context, from, to string) ([]CounterRow, error) {
	const q = `SELECT day, metric, key, count FROM counters_daily
	           WHERE day BETWEEN ? AND ? ORDER BY day, metric, key`
	rows, err := s.read.QueryContext(ctx, q, from, to)
	if err != nil {
		return nil, fmt.Errorf("query counters: %w", err)
	}
	defer func() { _ = rows.Close() }()

	var out []CounterRow
	for rows.Next() {
		var c CounterRow
		if err := rows.Scan(&c.Day, &c.Metric, &c.Key, &c.Count); err != nil {
			return nil, fmt.Errorf("scan counter: %w", err)
		}
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate counters: %w", err)
	}
	return out, nil
}

// EarliestDays reports where each history source starts, so the dashboard
// can say "collecting since" and resolve the "all" range.
func (s *Store) EarliestDays(ctx context.Context) (EarliestDays, error) {
	const q = `SELECT
	  COALESCE((SELECT MIN(day) FROM usage), ''),
	  COALESCE((SELECT MIN(day) FROM install_days), ''),
	  COALESCE((SELECT MIN(day) FROM counters_daily), ''),
	  COALESCE((SELECT MIN(first_seen) FROM installs), 0)`
	var (
		e         EarliestDays
		firstSeen int64
	)
	if err := s.read.QueryRowContext(ctx, q).Scan(&e.Usage, &e.InstallDays, &e.Counters, &firstSeen); err != nil {
		return EarliestDays{}, fmt.Errorf("read earliest days: %w", err)
	}
	if firstSeen > 0 {
		e.FirstSeen = time.Unix(firstSeen, 0).UTC().Format(dayLayout)
	}
	return e, nil
}

// ModelRow is one install's local-model verdicts for one UTC day and app
// version, as the phone last reported them.
type ModelRow struct {
	IDHash         string
	Day            string
	AppVersionCode int64
	Accepted       int64
	Declined       int64
	Unavailable    int64
}

// ModelRollupRow is every per-install row for one day and app version,
// folded together once it aged out of model_stats_daily. InstallCount is how
// many per-install rows went in.
type ModelRollupRow struct {
	Day            string
	AppVersionCode int64
	Accepted       int64
	Declined       int64
	Unavailable    int64
	InstallCount   int64
}

// AllModelStats reads every per-install model stats row, oldest day first.
func (s *Store) AllModelStats(ctx context.Context) ([]ModelRow, error) {
	return s.queryModel(ctx,
		`SELECT id_hash, day, app_version_code, accepted, declined, unavailable FROM model_stats_daily
		 ORDER BY day, id_hash, app_version_code`)
}

// ModelStatsBetween reads per-install model stats rows for days from..to
// inclusive.
func (s *Store) ModelStatsBetween(ctx context.Context, from, to string) ([]ModelRow, error) {
	return s.queryModel(ctx,
		`SELECT id_hash, day, app_version_code, accepted, declined, unavailable FROM model_stats_daily
		 WHERE day BETWEEN ? AND ? ORDER BY day, id_hash, app_version_code`,
		from, to)
}

func (s *Store) queryModel(ctx context.Context, q string, args ...any) ([]ModelRow, error) {
	rows, err := s.read.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, fmt.Errorf("query model stats: %w", err)
	}
	defer func() { _ = rows.Close() }()

	var out []ModelRow
	for rows.Next() {
		var m ModelRow
		if err := rows.Scan(&m.IDHash, &m.Day, &m.AppVersionCode, &m.Accepted, &m.Declined, &m.Unavailable); err != nil {
			return nil, fmt.Errorf("scan model stats: %w", err)
		}
		out = append(out, m)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate model stats: %w", err)
	}
	return out, nil
}

// ModelRollupBetween reads folded model stats for days from..to inclusive.
func (s *Store) ModelRollupBetween(ctx context.Context, from, to string) ([]ModelRollupRow, error) {
	const q = `SELECT day, app_version_code, accepted, declined, unavailable, install_count
	           FROM model_stats_rollup WHERE day BETWEEN ? AND ? ORDER BY day, app_version_code`
	rows, err := s.read.QueryContext(ctx, q, from, to)
	if err != nil {
		return nil, fmt.Errorf("query model rollup: %w", err)
	}
	defer func() { _ = rows.Close() }()

	var out []ModelRollupRow
	for rows.Next() {
		var r ModelRollupRow
		if err := rows.Scan(&r.Day, &r.AppVersionCode, &r.Accepted, &r.Declined, &r.Unavailable, &r.InstallCount); err != nil {
			return nil, fmt.Errorf("scan model rollup: %w", err)
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate model rollup: %w", err)
	}
	return out, nil
}

// MessagesArchived maps each install whose old model stats were folded into
// the rollup to the message total folded. Installs with none are absent.
func (s *Store) MessagesArchived(ctx context.Context) (map[string]int64, error) {
	const q = `SELECT id_hash, messages_archived FROM installs WHERE messages_archived > 0`
	rows, err := s.read.QueryContext(ctx, q)
	if err != nil {
		return nil, fmt.Errorf("query archived messages: %w", err)
	}
	defer func() { _ = rows.Close() }()

	out := map[string]int64{}
	for rows.Next() {
		var (
			hash string
			n    int64
		)
		if err := rows.Scan(&hash, &n); err != nil {
			return nil, fmt.Errorf("scan archived messages: %w", err)
		}
		out[hash] = n
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate archived messages: %w", err)
	}
	return out, nil
}
