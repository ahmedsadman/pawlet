package admin

import (
	"sync"
	"time"
)

// Login limits. Per address stops a single guesser; the global cap (raised to
// 100 so one IP at 5/15min = 20/h cannot fill it) stops a botnet spreading
// guesses thin, and also bounds the limiter's memory.
const (
	loginPerIPFailures  = 5
	loginPerIPWindow    = 15 * time.Minute
	loginGlobalFailures = 100
	loginGlobalWindow   = time.Hour
)

type attempt struct {
	ip string
	at time.Time
}

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

// begin reserves a login attempt slot. If allowed, the slot counts as a
// failure until succeed is called. Returns the attempt token and true if
// allowed, or zero value and false if rate limited.
func (l *loginLimiter) begin(ip string) (attempt, bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()

	// Prune expired global failures
	l.allFail = prune(l.allFail, now.Add(-loginGlobalWindow))

	// Prune expired entries from all IPs
	for k, times := range l.byIP {
		pruned := prune(times, now.Add(-loginPerIPWindow))
		if len(pruned) == 0 {
			delete(l.byIP, k)
		} else {
			l.byIP[k] = pruned
		}
	}

	// Check limits
	ipFails := l.byIP[ip]
	if len(ipFails) >= loginPerIPFailures || len(l.allFail) >= loginGlobalFailures {
		return attempt{}, false
	}

	// Reserve slot (counts as failure until proven otherwise)
	a := attempt{ip: ip, at: now}
	l.byIP[ip] = append(ipFails, now)
	l.allFail = append(l.allFail, now)
	return a, true
}

// succeed removes the attempt from both per-IP and global tracking.
func (l *loginLimiter) succeed(a attempt) {
	l.mu.Lock()
	defer l.mu.Unlock()

	// Remove the per-IP entry
	delete(l.byIP, a.ip)

	// Remove one matching entry from allFail
	for i, t := range l.allFail {
		if t.Equal(a.at) {
			l.allFail = append(l.allFail[:i], l.allFail[i+1:]...)
			break
		}
	}
}
