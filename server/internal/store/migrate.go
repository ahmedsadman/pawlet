package store

import (
	"context"
	"database/sql"
	_ "embed"
	"fmt"
)

//go:embed migrations/001_init.sql
var migration001 string

//go:embed migrations/002_admin_stats.sql
var migration002 string

//go:embed migrations/003_model_stats.sql
var migration003 string

// migrations moves the schema forward one version per entry: entry i takes a
// database from user_version i to i+1. Append only — never edit an entry that
// has shipped, because databases that already ran it will not run it again.
// Each migration runs inside a transaction, so PRAGMAs like journal_mode have
// no effect or fail, while foreign_keys is ignored. New columns must be nullable
// or have a DEFAULT so an older binary's INSERTs keep working (that's what makes
// rollback by image tag safe).
var migrations = []string{
	migration001,
	migration002,
	migration003,
}

// SchemaVersion is the user_version a database reports once every migration
// this binary knows has run.
func SchemaVersion() int { return len(migrations) }

// migrate applies every pending migration in order, each in its own
// transaction. A database newer than this binary is left alone: migrations
// are additive, so an older binary still finds every table and column it
// uses, and rolling back by image tag keeps working.
func migrate(ctx context.Context, db *sql.DB) error {
	var current int
	if err := db.QueryRowContext(ctx, "PRAGMA user_version").Scan(&current); err != nil {
		return fmt.Errorf("read schema version: %w", err)
	}
	for v := current; v < len(migrations); v++ {
		if err := applyMigration(ctx, db, v); err != nil {
			return err
		}
	}
	return nil
}

func applyMigration(ctx context.Context, db *sql.DB, from int) error {
	to := from + 1
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin migration %d: %w", to, err)
	}
	defer func() { _ = tx.Rollback() }()

	// A second process (e.g., an overlapping deploy) may have already applied
	// this migration while we waited on the write lock. Re-check inside the tx.
	var current int
	if err := tx.QueryRowContext(ctx, "PRAGMA user_version").Scan(&current); err != nil {
		return fmt.Errorf("re-check schema version: %w", err)
	}
	if current >= to {
		return nil // Already applied; rollback is a no-op.
	}

	if _, err := tx.ExecContext(ctx, migrations[from]); err != nil {
		return fmt.Errorf("apply migration %d: %w", to, err)
	}
	// PRAGMA takes no bound parameters; to is an int this function computed.
	if _, err := tx.ExecContext(ctx, fmt.Sprintf("PRAGMA user_version = %d", to)); err != nil { //nolint:gosec // integer, not input
		return fmt.Errorf("record schema version %d: %w", to, err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit migration %d: %w", to, err)
	}
	return nil
}
