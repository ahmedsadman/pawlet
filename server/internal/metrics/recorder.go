package metrics

import (
	"context"
	"log/slog"
	"sync"
	"time"
)

// Delta is one counter's accumulated increment for a UTC day, awaiting
// persistence.
type Delta struct {
	Day    string
	Metric string
	Key    string
	Count  int64
}

// Sink persists flushed counters. Declared here because this package consumes
// it; main adapts the store onto it.
type Sink interface {
	PersistCounters(ctx context.Context, deltas []Delta) error
}

type counterKey struct {
	day    string
	metric string
	key    string
}

// Recorder accumulates counters in memory between flushes.
type Recorder struct {
	sink Sink
	now  func() time.Time

	mu      sync.Mutex
	pending map[counterKey]int64
}

// New builds a Recorder. The clock is injected so tests can control the day.
func New(sink Sink, now func() time.Time) *Recorder {
	return &Recorder{sink: sink, now: now, pending: make(map[counterKey]int64)}
}

// Inc adds one to metric/key for the current UTC day.
func (r *Recorder) Inc(metric, key string) {
	day := r.now().UTC().Format("2006-01-02")
	r.mu.Lock()
	r.pending[counterKey{day: day, metric: metric, key: key}]++
	r.mu.Unlock()
}

// Flush persists and clears the accumulated counters. On a sink failure the
// counters are merged back so the next flush retries them.
func (r *Recorder) Flush(ctx context.Context) error {
	r.mu.Lock()
	if len(r.pending) == 0 {
		r.mu.Unlock()
		return nil
	}
	deltas := make([]Delta, 0, len(r.pending))
	for k, n := range r.pending {
		deltas = append(deltas, Delta{Day: k.day, Metric: k.metric, Key: k.key, Count: n})
	}
	r.pending = make(map[counterKey]int64)
	r.mu.Unlock()

	if err := r.sink.PersistCounters(ctx, deltas); err != nil {
		r.mu.Lock()
		for _, d := range deltas {
			r.pending[counterKey{day: d.Day, metric: d.Metric, key: d.Key}] += d.Count
		}
		r.mu.Unlock()
		return err
	}
	return nil
}

// RunFlusher flushes on an interval until ctx is cancelled, then flushes once
// more so a graceful shutdown does not drop the final counters.
func (r *Recorder) RunFlusher(ctx context.Context, every time.Duration, logger *slog.Logger) {
	if logger == nil {
		logger = slog.Default()
	}
	ticker := time.NewTicker(every)
	defer ticker.Stop()

	consecutiveFailures := 0
	for {
		select {
		case <-ctx.Done():
			if err := r.Flush(context.WithoutCancel(ctx)); err != nil {
				logger.Error("final metrics flush failed", "error", err)
			}
			return
		case <-ticker.C:
			if err := r.Flush(ctx); err != nil {
				consecutiveFailures++
				logger.Error("metrics flush failed", "error", err, "consecutive_failures", consecutiveFailures)
			} else {
				consecutiveFailures = 0
			}
		}
	}
}
