package admin

import (
	"sync"
	"time"
)

// Login limits. Per address stops a single guesser; the global cap stops a
// botnet spreading guesses thin, and also bounds the limiter's memory.
const (
	loginPerIPFailures  = 5
	loginPerIPWindow    = 15 * time.Minute
	loginGlobalFailures = 20
	loginGlobalWindow   = time.Hour
)

type loginLimiter struct {
	now func() time.Time

	mu      sync.Mutex
	byIP    map[string][]time.Time
	allFail []time.Time
}

func newLoginLimiter(now func() time.Time) *loginLimiter {
	return &loginLimiter{now: now, byIP: make(map[string][]time.Time)}
}

func prune(times []time.Time, cutoff time.Time) []time.Time {
	i := 0
	for i < len(times) && !times[i].After(cutoff) {
		i++
	}
	return times[i:]
}

// allow reports whether another attempt from ip may run the password check.
func (l *loginLimiter) allow(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	l.allFail = prune(l.allFail, now.Add(-loginGlobalWindow))
	fails := prune(l.byIP[ip], now.Add(-loginPerIPWindow))
	if len(fails) == 0 {
		delete(l.byIP, ip)
	} else {
		l.byIP[ip] = fails
	}
	return len(fails) < loginPerIPFailures && len(l.allFail) < loginGlobalFailures
}

func (l *loginLimiter) fail(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	l.byIP[ip] = append(l.byIP[ip], now)
	l.allFail = append(l.allFail, now)
}

func (l *loginLimiter) succeed(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.byIP, ip)
}
