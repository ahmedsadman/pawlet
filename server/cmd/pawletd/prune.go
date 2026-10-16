package main

import (
	"context"
	"log/slog"
	"time"
)

// pruneInterval is how often counted LLM message keys past retention are
// forgotten.
const pruneInterval = 24 * time.Hour

// llmMessagePruner forgets old LLM message keys; *store.Store satisfies it.
type llmMessagePruner interface {
	PruneLLMMessages(ctx context.Context, now time.Time) (int64, error)
}

// runLLMMessagePrune prunes once at startup and then on every tick until ctx
// is cancelled. A failure is logged and retried on the next tick.
func runLLMMessagePrune(ctx context.Context, pruner llmMessagePruner, every time.Duration,
	now func() time.Time, logger *slog.Logger,
) {
	ticker := time.NewTicker(every)
	defer ticker.Stop()

	for {
		n, err := pruner.PruneLLMMessages(ctx, now())
		switch {
		case err != nil && ctx.Err() != nil:
			// Shutting down: the prune was cut short, not broken.
		case err != nil:
			logger.Error("llm message prune failed", "error", err)
		case n > 0:
			logger.Info("llm message keys pruned", "rows", n)
		}

		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
