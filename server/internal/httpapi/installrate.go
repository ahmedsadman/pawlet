package httpapi

import (
	"sync"
	"time"
)

// RollingLimiter caps how many requests one key (an install hash) may make
// in any rolling window. It keeps each admitted request's time, so a caller
// at the limit is admitted again exactly one window after its oldest hit.
type RollingLimiter struct {
	capacity int
	window   time.Duration
	now      func() time.Time

	mu   sync.Mutex
	hits map[string][]time.Time
}

// NewRollingLimiter allows up to capacity requests per key in any window.
func NewRollingLimiter(capacity int, window time.Duration, now func() time.Time) *RollingLimiter {
	return &RollingLimiter{
		capacity: capacity,
		window:   window,
		now:      now,
		hits:     make(map[string][]time.Time),
	}
}

// Allow records a request for key when it is under the limit. When it is
// not, it returns how long until the oldest hit leaves the window.
func (l *RollingLimiter) Allow(key string) (bool, time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()

	now := l.now()
	recent := l.recent(key, now)
	if len(recent) >= l.capacity {
		l.hits[key] = recent
		return false, recent[0].Add(l.window).Sub(now)
	}
	l.hits[key] = append(recent, now)
	return true, 0
}

// Prune drops keys with no hit inside the window, so the map cannot grow
// without bound across a long uptime.
func (l *RollingLimiter) Prune() {
	l.mu.Lock()
	defer l.mu.Unlock()

	now := l.now()
	for key := range l.hits {
		if recent := l.recent(key, now); len(recent) == 0 {
			delete(l.hits, key)
		} else {
			l.hits[key] = recent
		}
	}
}

// recent returns key's hits still inside the window, oldest first. Must be
// called with the mutex held.
func (l *RollingLimiter) recent(key string, now time.Time) []time.Time {
	hits := l.hits[key]
	i := 0
	for i < len(hits) && !hits[i].After(now.Add(-l.window)) {
		i++
	}
	return hits[i:]
}

// modelStatsPerHour is how many /v1/model-stats requests one install may make
// in any rolling hour. The app sends at most once every six hours, so this
// only bites a misbehaving or scripted client.
const modelStatsPerHour = 12

// NewModelStatsLimiter builds the per-install limiter for /v1/model-stats.
func NewModelStatsLimiter(now func() time.Time) *RollingLimiter {
	return NewRollingLimiter(modelStatsPerHour, time.Hour, now)
}
