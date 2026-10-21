package store

import (
	"context"
	"fmt"
	"time"
)

// HeartbeatDay is what the app reported about one UTC day.
type HeartbeatDay struct {
	Day            string
	AppVersionCode int64
	// Opened: the app came to the foreground that day.
	Opened bool
	// Alive: the app ran that day. Stored as true whenever Opened is.
	Alive bool
	// LLM: which LLM group the install is in (empty when not reported).
	LLM string
}

// RecordHeartbeat stores one install's reported days in one transaction.
//
// A missing install is created unattested; an existing one only gets
// last_seen = now, so its attested flag and verdict fields are untouched.
// Day flags only ever go from 0 to 1, so a resend or an out-of-order batch
// never clears one. A day's version only moves up: Play never downgrades an
// install. The install's version is then taken from its newest day that has
// one, so a late batch of old days cannot roll it back.
func (s *Store) RecordHeartbeat(ctx context.Context, idHash string, now time.Time, days []HeartbeatDay) error {
	if len(days) == 0 {
		return nil
	}

	tx, err := s.write.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin heartbeat tx: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	const upsertInstall = `INSERT INTO installs (id_hash, first_seen, last_seen, attested)
	  VALUES (?, ?, ?, 0)
	  ON CONFLICT(id_hash) DO UPDATE SET last_seen = excluded.last_seen`
	if _, err := tx.ExecContext(ctx, upsertInstall, idHash, now.Unix(), now.Unix()); err != nil {
		return fmt.Errorf("heartbeat install: %w", err)
	}

	const upsertDay = `INSERT INTO install_days (id_hash, day, app_version_code, opened, alive, session, llm)
	  VALUES (?, ?, ?, ?, ?, 0, ?)
	  ON CONFLICT(id_hash, day) DO UPDATE SET
	    app_version_code = COALESCE(MAX(install_days.app_version_code, excluded.app_version_code), install_days.app_version_code, excluded.app_version_code),
	    opened           = MAX(install_days.opened, excluded.opened),
	    alive            = MAX(install_days.alive, excluded.alive),
	    llm              = COALESCE(excluded.llm, install_days.llm)`
	stmt, err := tx.PrepareContext(ctx, upsertDay)
	if err != nil {
		return fmt.Errorf("prepare heartbeat day upsert: %w", err)
	}
	defer func() { _ = stmt.Close() }()
	for _, d := range days {
		if _, err := stmt.ExecContext(ctx, idHash, d.Day, nullInt(d.AppVersionCode),
			boolInt(d.Opened), boolInt(d.Alive || d.Opened), nullString(d.LLM)); err != nil {
			return fmt.Errorf("heartbeat day %s: %w", d.Day, err)
		}
	}

	const syncVersion = `UPDATE installs SET app_version_code = (
	    SELECT app_version_code FROM install_days
	    WHERE id_hash = ? AND app_version_code IS NOT NULL
	    ORDER BY day DESC LIMIT 1)
	  WHERE id_hash = ?`
	if _, err := tx.ExecContext(ctx, syncVersion, idHash, idHash); err != nil {
		return fmt.Errorf("heartbeat version: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit heartbeat tx: %w", err)
	}
	return nil
}
