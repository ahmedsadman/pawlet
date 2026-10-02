// Package quota enforces per-install and global call limits.
package quota

import (
	"context"
	"log/slog"
	"sync"
	"time"
)

// Reason explains a denial.
type Reason int

// Denial reasons.
const (
	ReasonNone Reason = iota
	ReasonBurst
	ReasonDaily
	ReasonGlobal
)

// Delta is one install's accumulated usage for a UTC day, awaiting persistence.
type Delta struct {
	IDHash string
	Day    string
	Calls  int64
	Tokens int64
}

// Sink persists flushed counters.
type Sink interface {
	PersistUsage(ctx context.Context, deltas []Delta) error
	LoadUsage(ctx context.Context, day string) (map[string]int64, error)
}

// Limits are the configured ceilings.
type Limits struct {
	Daily       int
	Burst       int
	GlobalDaily int
}

// Decision is the verdict for one admission attempt.
type Decision struct {
	Allowed    bool
	Reason     Reason
	RetryAfter time.Duration
	Day        string
}

type counter struct {
	day        string
	dailyCalls int64
	minute     int64
	minuteHits int
}

// Limiter tracks counters in memory and flushes them on an interval.
type Limiter struct {
	limits Limits
	sink   Sink
	now    func() time.Time

	mu       sync.Mutex
	installs map[string]*counter
	global   counter
	pending  map[string]*Delta
}

// New builds a Limiter. The clock is injected so tests can advance time.
func New(limits Limits, sink Sink, now func() time.Time) *Limiter {
	return &Limiter{
		limits:   limits,
		sink:     sink,
		now:      now,
		installs: make(map[string]*counter),
		pending:  make(map[string]*Delta),
	}
}

// Hydrate seeds the limiter from today's persisted usage so counters survive
// a restart. Call once at startup, before serving requests.
func (l *Limiter) Hydrate(ctx context.Context) error {
	day := l.now().UTC().Format("2006-01-02")
	usage, err := l.sink.LoadUsage(ctx, day)
	if err != nil {
		return err
	}

	l.mu.Lock()
	defer l.mu.Unlock()

	var globalSum int64
	for idHash, calls := range usage {
		c := &counter{
			day:        day,
			dailyCalls: calls,
		}
		l.installs[idHash] = c
		globalSum += calls
	}

	l.global.day = day
	l.global.dailyCalls = globalSum

	return nil
}

// Admit records one call against idHash when every limit allows it.
func (l *Limiter) Admit(idHash string) Decision {
	now := l.now().UTC()
	day := now.Format("2006-01-02")
	minute := now.Unix() / 60

	l.mu.Lock()
	defer l.mu.Unlock()

	rollDay(&l.global, day)
	if l.global.dailyCalls >= int64(l.limits.GlobalDaily) {
		return Decision{Reason: ReasonGlobal, RetryAfter: untilNextDay(now)}
	}

	c := l.installs[idHash]
	if c == nil {
		c = &counter{}
		l.installs[idHash] = c
	}
	rollDay(c, day)

	if c.minute != minute {
		c.minute = minute
		c.minuteHits = 0
	}
	if c.minuteHits >= l.limits.Burst {
		return Decision{Reason: ReasonBurst, RetryAfter: untilNextMinute(now)}
	}
	if c.dailyCalls >= int64(l.limits.Daily) {
		return Decision{Reason: ReasonDaily, RetryAfter: untilNextDay(now)}
	}

	c.minuteHits++
	c.dailyCalls++
	l.global.dailyCalls++
	l.pendingFor(idHash, day).Calls++

	return Decision{Allowed: true, Day: day}
}

// RecordTokens attributes token usage to an admitted call.
func (l *Limiter) RecordTokens(idHash, day string, tokens int64) {
	if tokens <= 0 {
		return
	}

	l.mu.Lock()
	defer l.mu.Unlock()
	l.pendingFor(idHash, day).Tokens += tokens
}

// Flush persists and clears the accumulated deltas.
func (l *Limiter) Flush(ctx context.Context) error {
	l.mu.Lock()
	if len(l.pending) == 0 {
		l.mu.Unlock()
		return nil
	}
	deltas := make([]Delta, 0, len(l.pending))
	for _, d := range l.pending {
		deltas = append(deltas, *d)
	}
	l.pending = make(map[string]*Delta)
	l.mu.Unlock()

	if err := l.sink.PersistUsage(ctx, deltas); err != nil {
		// Restore the deltas so a transient store failure does not lose them.
		l.mu.Lock()
		for i := range deltas {
			p := l.pendingFor(deltas[i].IDHash, deltas[i].Day)
			p.Calls += deltas[i].Calls
			p.Tokens += deltas[i].Tokens
		}
		l.mu.Unlock()
		return err
	}
	return nil
}

// RunFlusher flushes on an interval until ctx is cancelled, then flushes once
// more so a graceful shutdown does not drop the final counters.
func (l *Limiter) RunFlusher(ctx context.Context, every time.Duration, logger *slog.Logger) {
	if logger == nil {
		logger = slog.Default()
	}
	ticker := time.NewTicker(every)
	defer ticker.Stop()

	consecutiveFailures := 0
	for {
		select {
		case <-ctx.Done():
			if err := l.Flush(context.WithoutCancel(ctx)); err != nil {
				logger.Error("final flush failed", "error", err)
			}
			return
		case <-ticker.C:
			l.evictStale(l.now().UTC().Format("2006-01-02"))
			if err := l.Flush(ctx); err != nil {
				consecutiveFailures++
				logger.Error("flush failed", "error", err, "consecutive_failures", consecutiveFailures)
			} else {
				consecutiveFailures = 0
			}
		}
	}
}

// pendingFor must be called with the mutex held.
func (l *Limiter) pendingFor(idHash, day string) *Delta {
	key := idHash + "|" + day
	d := l.pending[key]
	if d == nil {
		d = &Delta{IDHash: idHash, Day: day}
		l.pending[key] = d
	}
	return d
}

func rollDay(c *counter, day string) {
	if c.day != day {
		c.day = day
		c.dailyCalls = 0
	}
}

func untilNextMinute(now time.Time) time.Duration {
	return time.Duration(60-now.Unix()%60) * time.Second
}

func untilNextDay(now time.Time) time.Duration {
	next := now.Truncate(24 * time.Hour).Add(24 * time.Hour)
	return next.Sub(now)
}

// evictStale removes install counters from previous days. Must be called with
// the mutex held.
func (l *Limiter) evictStale(day string) {
	for idHash, c := range l.installs {
		if c.day != day {
			delete(l.installs, idHash)
		}
	}
}
