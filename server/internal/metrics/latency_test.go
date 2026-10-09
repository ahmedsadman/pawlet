package metrics

import (
	"testing"
	"time"
)

func TestLatencyBucket(t *testing.T) {
	cases := []struct {
		in   time.Duration
		want string
	}{
		{0, "250"},
		{250 * time.Millisecond, "250"},
		{251 * time.Millisecond, "500"},
		{999 * time.Millisecond, "1000"},
		{1500 * time.Millisecond, "2000"},
		{2 * time.Second, "2000"},
		{3400 * time.Millisecond, "4000"},
		{8 * time.Second, "8000"},
		{12 * time.Second, "16000"},
		{32 * time.Second, "32000"},
		{32001 * time.Millisecond, "inf"},
		{5 * time.Minute, "inf"},
	}
	for _, c := range cases {
		if got := LatencyBucket(c.in); got != c.want {
			t.Errorf("LatencyBucket(%v) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestLatencyBoundsMsIsACopy(t *testing.T) {
	b := LatencyBoundsMs()
	if len(b) != 8 || b[0] != 250 || b[7] != 32000 {
		t.Fatalf("LatencyBoundsMs() = %v", b)
	}
	b[0] = 1
	if LatencyBoundsMs()[0] != 250 {
		t.Fatal("LatencyBoundsMs() exposed the shared slice")
	}
}
