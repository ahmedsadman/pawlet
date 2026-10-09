package admin

import (
	"fmt"
	"sync"
	"testing"
	"time"
)

func TestLoginLimiterPerIP(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	l := newLoginLimiter(func() time.Time { return now })
	for i := 0; i < 5; i++ {
		if _, ok := l.begin("1.1.1.1"); !ok {
			t.Fatalf("attempt %d refused", i)
		}
	}
	if _, ok := l.begin("1.1.1.1"); ok {
		t.Fatal("sixth attempt within 15 minutes allowed")
	}
	if _, ok := l.begin("2.2.2.2"); !ok {
		t.Fatal("another address refused")
	}
	now = now.Add(15*time.Minute + time.Second)
	if _, ok := l.begin("1.1.1.1"); !ok {
		t.Fatal("still refused after the window")
	}
}

func TestLoginLimiterSuccessResetsAddress(t *testing.T) {
	l := newLoginLimiter(func() time.Time { return time.Unix(1_700_000_000, 0) })
	for i := 0; i < 4; i++ {
		l.begin("1.1.1.1")
	}
	a, _ := l.begin("1.1.1.1")
	l.succeed(a)
	for i := 0; i < 5; i++ {
		if _, ok := l.begin("1.1.1.1"); !ok {
			t.Fatalf("attempt %d refused after a success", i)
		}
	}
}

func TestLoginLimiterGlobal(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	l := newLoginLimiter(func() time.Time { return now })
	for i := 0; i < 100; i++ {
		l.begin(fmt.Sprintf("10.0.0.%d", i))
	}
	if _, ok := l.begin("9.9.9.9"); ok {
		t.Fatal("fresh address allowed after 100 failures in the hour")
	}
	now = now.Add(time.Hour + time.Second)
	if _, ok := l.begin("9.9.9.9"); !ok {
		t.Fatal("still refused after the global window")
	}
}

func TestLoginLimiterConcurrentBegin(t *testing.T) {
	l := newLoginLimiter(time.Now)
	var wg sync.WaitGroup
	succeeded := make(chan bool, 50)
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, ok := l.begin("1.2.3.4")
			succeeded <- ok
		}()
	}
	wg.Wait()
	close(succeeded)
	count := 0
	for ok := range succeeded {
		if ok {
			count++
		}
	}
	if count != 5 {
		t.Fatalf("concurrent begin: %d succeeded, want 5", count)
	}
}

func TestLoginLimiterSuccessFreesGlobalSlot(t *testing.T) {
	l := newLoginLimiter(func() time.Time { return time.Unix(1_700_000_000, 0) })
	for i := 0; i < 99; i++ {
		l.begin(fmt.Sprintf("10.0.0.%d", i))
	}
	a, ok := l.begin("winner")
	if !ok {
		t.Fatal("100th attempt refused")
	}
	if _, ok := l.begin("blocked"); ok {
		t.Fatal("101st attempt allowed")
	}
	l.succeed(a)
	if _, ok := l.begin("now-ok"); !ok {
		t.Fatal("attempt refused after a success freed a global slot")
	}
}
