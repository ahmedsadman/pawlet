package httpapi

import (
	"fmt"
	"math"
	"time"

	"github.com/ahmedsadman/pawlet/server/internal/store"
)

// Limits on a /v1/model-stats body. The app sends at most the last 30 UTC
// days, one row per (day, app version).
const (
	modelStatsMaxBody    = 4 << 10
	modelStatsMaxDays    = 31
	modelStatsPastDays   = 30
	modelStatsFutureDays = 1 // a phone clock slightly ahead of UTC midnight
	modelStatsMaxCount   = 100_000
)

type modelStatsRequest struct {
	Days []modelStatsEntry `json:"days"`
}

type modelStatsEntry struct {
	Day            string `json:"day"`
	AppVersionCode int64  `json:"appVersionCode"`
	Accepted       int64  `json:"accepted"`
	Declined       int64  `json:"declined"`
	Unavailable    int64  `json:"unavailable"`
}

// validateModelStats checks a decoded body against the limits above and
// returns it as store rows. today is the server's current time; only its UTC
// day matters.
func validateModelStats(req modelStatsRequest, today time.Time) ([]store.ModelStatsDay, error) {
	if len(req.Days) == 0 || len(req.Days) > modelStatsMaxDays {
		return nil, fmt.Errorf("want 1-%d days, got %d", modelStatsMaxDays, len(req.Days))
	}
	utc := today.UTC()
	earliest := utc.AddDate(0, 0, -modelStatsPastDays).Format(time.DateOnly)
	latest := utc.AddDate(0, 0, modelStatsFutureDays).Format(time.DateOnly)

	type key struct {
		day     string
		version int64
	}
	seen := make(map[key]bool, len(req.Days))
	out := make([]store.ModelStatsDay, 0, len(req.Days))
	for i, e := range req.Days {
		parsed, err := time.Parse(time.DateOnly, e.Day)
		if err != nil || parsed.Format(time.DateOnly) != e.Day {
			return nil, fmt.Errorf("entry %d: day is not YYYY-MM-DD", i)
		}
		// YYYY-MM-DD strings sort in date order, so string bounds suffice.
		if e.Day < earliest || e.Day > latest {
			return nil, fmt.Errorf("entry %d: day %s outside %s..%s", i, e.Day, earliest, latest)
		}
		if e.AppVersionCode < 1 || e.AppVersionCode > math.MaxInt32 {
			return nil, fmt.Errorf("entry %d: appVersionCode out of range", i)
		}
		for _, n := range []int64{e.Accepted, e.Declined, e.Unavailable} {
			if n < 0 || n > modelStatsMaxCount {
				return nil, fmt.Errorf("entry %d: count out of range", i)
			}
		}
		k := key{e.Day, e.AppVersionCode}
		if seen[k] {
			return nil, fmt.Errorf("entry %d: duplicate day and appVersionCode", i)
		}
		seen[k] = true
		out = append(out, store.ModelStatsDay{
			Day:            e.Day,
			AppVersionCode: e.AppVersionCode,
			Accepted:       e.Accepted,
			Declined:       e.Declined,
			Unavailable:    e.Unavailable,
		})
	}
	return out, nil
}
