// Package stats turns raw store rows into the numbers the admin dashboard
// shows. It does no I/O: every function is a pure transform, so each metric
// definition is pinned down by a unit test.
package stats

import (
	"errors"
	"time"
)

// DayLayout is the UTC day key every table uses.
const DayLayout = "2006-01-02"

// ErrBadRequest reports a query parameter the caller should fix.
var ErrBadRequest = errors.New("stats: bad request")

func parseDay(day string) time.Time {
	t, _ := time.Parse(DayLayout, day)
	return t
}

// Today is now's UTC day key.
func Today(now time.Time) string { return now.UTC().Format(DayLayout) }

// AddDays shifts a day key by n days.
func AddDays(day string, n int) string {
	return parseDay(day).AddDate(0, 0, n).Format(DayLayout)
}

// Days lists every day from from to to inclusive; empty when from > to.
func Days(from, to string) []string {
	end := parseDay(to)
	var out []string
	for d := parseDay(from); !d.After(end); d = d.AddDate(0, 0, 1) {
		out = append(out, d.Format(DayLayout))
	}
	return out
}

// WeekStart is the Monday of day's ISO week.
func WeekStart(day string) string {
	t := parseDay(day)
	offset := (int(t.Weekday()) + 6) % 7
	return t.AddDate(0, 0, -offset).Format(DayLayout)
}

// Range is an inclusive span of UTC days. All marks range=all: it starts
// with the history, so it has no previous period to compare against.
type Range struct {
	From string `json:"from"`
	To   string `json:"to"`
	All  bool   `json:"-"`
}

// ParseRange resolves 7d, 30d (the default), 90d or all, each ending today.
// "all" starts at earliest, or today when there is no history yet.
func ParseRange(s, today, earliest string) (Range, error) {
	switch s {
	case "", "30d":
		return Range{From: AddDays(today, -29), To: today}, nil
	case "7d":
		return Range{From: AddDays(today, -6), To: today}, nil
	case "90d":
		return Range{From: AddDays(today, -89), To: today}, nil
	case "all":
		if earliest == "" || earliest > today {
			return Range{From: today, To: today, All: true}, nil
		}
		return Range{From: earliest, To: today, All: true}, nil
	}
	return Range{}, ErrBadRequest
}
