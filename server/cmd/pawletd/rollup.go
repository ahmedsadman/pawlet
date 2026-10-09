package main

import (
	"context"
	"log/slog"
	"time"

	"github.com/ahmedsadman/pawlet/server/internal/store"
)

// rollupInterval is how often old per-install model stats are folded.
const rollupInterval = 24 * time.Hour

// modelStatsRoller folds old per-install model stats; *store.Store satisfies it.
type modelStatsRoller interface {
	RollupModelStats(ctx context.Context, now time.Time) (store.RollupResult, error)
}

// runModelStatsRollup folds once at startup and then on every tick until ctx
// is cancelled. A failure is logged and retried on the next tick; a fold is
// one transaction, so a failed run leaves nothing half-done.
func runModelStatsRollup(ctx context.Context, roller modelStatsRoller, every time.Duration,
	now func() time.Time, logger *slog.Logger,
) {
	ticker := time.NewTicker(every)
	defer ticker.Stop()

	for {
		res, err := roller.RollupModelStats(ctx, now())
		switch {
		case err != nil:
			logger.Error("model stats rollup failed", "error", err)
		case res.Rows > 0:
			logger.Info("model stats rolled up", "rows", res.Rows, "messages", res.Messages)
		}

		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
