package stats

import "github.com/ahmedsadman/pawlet/server/internal/store"

// Mode chooses what counts as an active day.
type Mode string

// Activity modes.
const (
	// ModeAny counts a classify call or a minted session: closest to "the
	// user opened the app".
	ModeAny Mode = "any"
	// ModeClassify counts only classify calls: closest to "the user cost
	// tokens".
	ModeClassify Mode = "classify"
)

// ParseMode resolves the active= parameter; empty means any.
func ParseMode(s string) (Mode, error) {
	switch s {
	case "", string(ModeAny):
		return ModeAny, nil
	case string(ModeClassify):
		return ModeClassify, nil
	}
	return "", ErrBadRequest
}

// Activity is the set of installs active on each day.
type Activity map[string]map[string]struct{}

func (a Activity) mark(day, hash string) {
	set := a[day]
	if set == nil {
		set = make(map[string]struct{})
		a[day] = set
	}
	set[hash] = struct{}{}
}

// Active reports whether hash was active on day.
func (a Activity) Active(day, hash string) bool {
	_, ok := a[day][hash]
	return ok
}

func (a Activity) distinct(from, to string) int {
	seen := make(map[string]struct{})
	for _, d := range Days(from, to) {
		for h := range a[d] {
			seen[h] = struct{}{}
		}
	}
	return len(seen)
}

func (a Activity) activeBetween(hash, from, to string) bool {
	for _, d := range Days(from, to) {
		if a.Active(d, hash) {
			return true
		}
	}
	return false
}

// BuildActivity marks a usage day with calls as active, plus every session
// day in ModeAny.
func BuildActivity(usage []store.UsageRow, sessions []store.DayRow, mode Mode) Activity {
	a := Activity{}
	for _, u := range usage {
		if u.Calls > 0 {
			a.mark(u.Day, u.IDHash)
		}
	}
	if mode == ModeAny {
		for _, s := range sessions {
			a.mark(s.Day, s.IDHash)
		}
	}
	return a
}

// ActiveCount is DAU, WAU, MAU and stickiness for one day.
type ActiveCount struct {
	Day        string  `json:"day"`
	DAU        int     `json:"dau"`
	WAU        int     `json:"wau"`
	MAU        int     `json:"mau"`
	Stickiness float64 `json:"stickiness"`
}

// ActiveSeries computes rolling active counts for each day. The activity
// must reach 29 days before the first day for MAU to be complete.
func ActiveSeries(a Activity, days []string) []ActiveCount {
	out := make([]ActiveCount, 0, len(days))
	for _, d := range days {
		c := ActiveCount{
			Day: d,
			DAU: len(a[d]),
			WAU: a.distinct(AddDays(d, -6), d),
			MAU: a.distinct(AddDays(d, -29), d),
		}
		if c.MAU > 0 {
			c.Stickiness = float64(c.DAU) / float64(c.MAU)
		}
		out = append(out, c)
	}
	return out
}
