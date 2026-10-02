// Package attest issues anti-replay challenges and verifies Play Integrity
// verdicts.
package attest

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"sync"
	"time"
)

// Challenges issues single-use nonces and consumes them exactly once.
//
// Held in memory deliberately: the service is a single instance and the
// lifetime is two minutes, so a restart merely forces clients to re-mint.
type Challenges struct {
	ttl time.Duration
	now func() time.Time

	mu     sync.Mutex
	issued map[string]time.Time
}

// NewChallenges builds a store with the given lifetime.
func NewChallenges(ttl time.Duration, now func() time.Time) *Challenges {
	return &Challenges{ttl: ttl, now: now, issued: make(map[string]time.Time)}
}

// Issue returns a fresh 32-byte challenge, hex encoded.
func (c *Challenges) Issue() (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("generate challenge: %w", err)
	}
	value := hex.EncodeToString(buf)

	c.mu.Lock()
	defer c.mu.Unlock()
	c.issued[value] = c.now().Add(c.ttl)
	return value, nil
}

// Consume spends a challenge, reporting whether it was valid and unexpired.
// The delete and the check happen under one lock, so concurrent callers cannot
// both spend the same value.
func (c *Challenges) Consume(value string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()

	expiry, ok := c.issued[value]
	if !ok {
		return false
	}
	delete(c.issued, value)
	return c.now().Before(expiry)
}

// Prune drops expired entries so an unused challenge cannot accumulate.
func (c *Challenges) Prune() {
	now := c.now()

	c.mu.Lock()
	defer c.mu.Unlock()
	for value, expiry := range c.issued {
		if !now.Before(expiry) {
			delete(c.issued, value)
		}
	}
}

// Len reports the number of live challenges.
func (c *Challenges) Len() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.issued)
}

// RunJanitor prunes on an interval until ctx is cancelled.
func (c *Challenges) RunJanitor(ctx context.Context, every time.Duration) {
	ticker := time.NewTicker(every)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			c.Prune()
		}
	}
}
