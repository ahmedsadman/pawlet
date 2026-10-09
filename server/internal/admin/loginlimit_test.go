package admin

import (
	"fmt"
	"testing"
	"time"
)

func TestLoginLimiterPerIP(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	l := newLoginLimiter(func() time.Time { return now })
	for i := 0; i < 5; i++ {
		if !l.allow("1.1.1.1") {
			t.Fatalf("attempt %d refused", i)
		}
		l.fail("1.1.1.1")
	}
	if l.allow("1.1.1.1") {
		t.Fatal("sixth attempt within 15 minutes allowed")
	}
	if !l.allow("2.2.2.2") {
		t.Fatal("another address refused")
	}
	now = now.Add(15*time.Minute + time.Second)
	if !l.allow("1.1.1.1") {
		t.Fatal("still refused after the window")
	}
}

func TestLoginLimiterSuccessResetsAddress(t *testing.T) {
	l := newLoginLimiter(func() time.Time { return time.Unix(1_700_000_000, 0) })
	for i := 0; i < 4; i++ {
		l.fail("1.1.1.1")
	}
	l.succeed("1.1.1.1")
	for i := 0; i < 5; i++ {
		if !l.allow("1.1.1.1") {
			t.Fatalf("attempt %d refused after a success", i)
		}
		l.fail("1.1.1.1")
	}
}

func TestLoginLimiterGlobal(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	l := newLoginLimiter(func() time.Time { return now })
	for i := 0; i < 20; i++ {
		l.fail(fmt.Sprintf("10.0.0.%d", i))
	}
	if l.allow("9.9.9.9") {
		t.Fatal("fresh address allowed after 20 failures in the hour")
	}
	now = now.Add(time.Hour + time.Second)
	if !l.allow("9.9.9.9") {
		t.Fatal("still refused after the global window")
	}
}
