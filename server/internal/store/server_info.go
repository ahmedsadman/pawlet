package store

import (
	"context"
	"fmt"
)

// Keys pawletd publishes to server_info at startup. The admin dashboard reads
// them, so renaming one is a cross-binary change.
const (
	InfoDailyPerInstall = "daily_per_install"
	InfoBurstPerMin     = "burst_per_min"
	InfoGlobalDailyCap  = "global_daily_cap"
	InfoModels          = "models"
	InfoStartedAt       = "started_at"
	InfoImageTag        = "image_tag"
)

// PutServerInfo upserts every entry in one transaction. Keys absent from info
// keep their previous value.
func (s *Store) PutServerInfo(ctx context.Context, info map[string]string) error {
	tx, err := s.write.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin server info tx: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	const q = `INSERT INTO server_info (key, value) VALUES (?, ?)
	           ON CONFLICT(key) DO UPDATE SET value = excluded.value`
	for k, v := range info {
		if _, err := tx.ExecContext(ctx, q, k, v); err != nil {
			return fmt.Errorf("upsert server info %s: %w", k, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit server info tx: %w", err)
	}
	return nil
}

// ServerInfo reads every published entry.
func (s *Store) ServerInfo(ctx context.Context) (map[string]string, error) {
	rows, err := s.read.QueryContext(ctx, `SELECT key, value FROM server_info`)
	if err != nil {
		return nil, fmt.Errorf("query server info: %w", err)
	}
	defer func() { _ = rows.Close() }()

	info := make(map[string]string)
	for rows.Next() {
		var k, v string
		if err := rows.Scan(&k, &v); err != nil {
			return nil, fmt.Errorf("scan server info: %w", err)
		}
		info[k] = v
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate server info: %w", err)
	}
	return info, nil
}
