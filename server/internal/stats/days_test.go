package stats

import (
	"errors"
	"testing"
	"time"
)

func TestDays(t *testing.T) {
	got := Days("2026-09-29", "2026-10-02")
	want := []string{"2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02"}
	if len(got) != len(want) {
		t.Fatalf("Days() = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("Days() = %v, want %v", got, want)
		}
	}
	if len(Days("2026-10-02", "2026-10-01")) != 0 {
		t.Fatal("Days(from > to) should be empty")
	}
}

func TestAddDaysAndToday(t *testing.T) {
	if got := AddDays("2026-03-01", -1); got != "2026-02-28" {
		t.Fatalf("AddDays() = %q", got)
	}
	dhaka := time.FixedZone("BST", 6*3600)
	if got := Today(time.Date(2026, 10, 9, 2, 0, 0, 0, dhaka)); got != "2026-10-08" {
		t.Fatalf("Today() = %q, want UTC day", got)
	}
}

func TestWeekStartIsMonday(t *testing.T) {
	cases := map[string]string{
		"2026-10-05": "2026-10-05", // Monday
		"2026-10-09": "2026-10-05", // Friday
		"2026-10-11": "2026-10-05", // Sunday
		"2026-10-12": "2026-10-12",
	}
	for in, want := range cases {
		if got := WeekStart(in); got != want {
			t.Errorf("WeekStart(%s) = %s, want %s", in, got, want)
		}
	}
}

func TestParseRange(t *testing.T) {
	today := "2026-10-09"
	cases := []struct {
		in, earliest string
		want         Range
	}{
		{"", "", Range{"2026-09-10", today}},
		{"30d", "", Range{"2026-09-10", today}},
		{"7d", "", Range{"2026-10-03", today}},
		{"90d", "", Range{"2026-07-12", today}},
		{"all", "2026-08-01", Range{"2026-08-01", today}},
		{"all", "", Range{today, today}},
	}
	for _, c := range cases {
		got, err := ParseRange(c.in, today, c.earliest)
		if err != nil || got != c.want {
			t.Errorf("ParseRange(%q) = %+v, %v; want %+v", c.in, got, err, c.want)
		}
	}
	if _, err := ParseRange("1y", today, ""); !errors.Is(err, ErrBadRequest) {
		t.Fatalf("ParseRange(1y) err = %v, want ErrBadRequest", err)
	}
}
