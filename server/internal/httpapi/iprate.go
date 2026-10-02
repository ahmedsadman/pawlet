package httpapi

import (
	"sync"
	"time"
)

// hourlyLimiter caps how often one address may hit an endpoint. Entries are
// keyed by hour so a new hour resets a caller without needing a sweep.
type hourlyLimiter struct {
	capacity int
	now      func() time.Time
	mu       sync.Mutex
	entries  map[string]*hourlyEntry
}

type hourlyEntry struct {
	hour  int // Hour since epoch: now.Unix() / 3600
	count int
}

// newHourlyLimiter builds a limiter that allows up to capacity requests per
// address per hour.
func newHourlyLimiter(capacity int, now func() time.Time) *hourlyLimiter {
	return &hourlyLimiter{
		capacity: capacity,
		now:      now,
		entries:  make(map[string]*hourlyEntry),
	}
}

// allow returns true if the caller is under the limit. An entry whose recorded
// hour differs from the current hour resets to zero before the check.
func (l *hourlyLimiter) allow(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()

	currentHour := int(l.now().Unix() / 3600)
	entry, exists := l.entries[key]

	if !exists {
		// First request from this address this hour.
		l.entries[key] = &hourlyEntry{hour: currentHour, count: 1}
		return true
	}

	if entry.hour != currentHour {
		// New hour, reset the counter.
		entry.hour = currentHour
		entry.count = 1
		return true
	}

	// Same hour, check capacity.
	if entry.count >= l.capacity {
		return false
	}

	entry.count++
	return true
}

// Prune drops entries from previous hours so the map cannot grow unbounded
// across a long uptime.
func (l *hourlyLimiter) Prune() {
	l.mu.Lock()
	defer l.mu.Unlock()

	currentHour := int(l.now().Unix() / 3600)
	for key, entry := range l.entries {
		if entry.hour < currentHour {
			delete(l.entries, key)
		}
	}
}

// NewChallengeLimiter builds a limiter for the challenge endpoint, using the
// real clock.
//
//nolint:revive // returns unexported type; callers only need to pass it through
func NewChallengeLimiter(perHour int) *hourlyLimiter {
	return newHourlyLimiter(perHour, time.Now)
}
