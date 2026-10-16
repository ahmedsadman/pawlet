package stats

import "github.com/ahmedsadman/pawlet/server/internal/store"

// Mode chooses what counts as an active day.
type Mode string

// Activity modes.
const (
	// ModeAny counts any sign the app ran that day: a heartbeat (opened or
	// running in the background), a minted session, or a classify call.
	ModeAny Mode = "any"
	// ModeOpened counts days the app came to the foreground. A session day
	// counts too: sessions are only minted in the foreground, and app builds
	// without heartbeats report nothing else.
	ModeOpened Mode = "opened"
	// ModeClassify counts only classify calls: closest to "the user cost
	// tokens".
	ModeClassify Mode = "classify"
)

// ParseMode resolves the active= parameter; empty means any.
func ParseMode(s string) (Mode, error) {
	switch s {
	case "", string(ModeAny):
		return ModeAny, nil
	case string(ModeOpened):
		return ModeOpened, nil
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

// classified reports whether the install made any classify call that day.
// Attempts is the signal: a day of retries alone counts no new call. Calls is
// checked too because a pawletd rolled back past the attempts column writes
// calls only.
func classified(u store.UsageRow) bool { return u.Attempts > 0 || u.Calls > 0 }

// BuildActivity marks the days each install was active under mode. Classify
// calls count in ModeAny and ModeClassify. In ModeAny every install_days row
// counts, whatever its flags: a row only exists once some signal arrived.
func BuildActivity(usage []store.UsageRow, days []store.DayRow, mode Mode) Activity {
	a := Activity{}
	if mode != ModeOpened {
		for _, u := range usage {
			if classified(u) {
				a.mark(u.Day, u.IDHash)
			}
		}
	}
	for _, d := range days {
		if mode == ModeAny || (mode == ModeOpened && (d.Opened || d.Session)) {
			a.mark(d.Day, d.IDHash)
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
