package stats

import (
	"slices"
	"strconv"

	"github.com/ahmedsadman/pawlet/server/internal/store"
)

// FleetWindowDays: the fleet page describes installs active in this many
// trailing days.
const FleetWindowDays = 30

// Unknown is the key for an install whose verdict did not carry a value.
const Unknown = "unknown"

// Fleet is what the fleet page plots.
type Fleet struct {
	ActiveInstalls int         `json:"activeInstalls"`
	Versions       []KeyCount  `json:"versions"`
	DeviceTier     []KeyCount  `json:"deviceTier"`
	Licensing      []KeyCount  `json:"licensing"`
	SDK            []KeyCount  `json:"sdk"`
	Adoption       []DayCounts `json:"adoption"`
}

func intKey(v int64) string {
	if v == 0 {
		return Unknown
	}
	return strconv.FormatInt(v, 10)
}

func strKey(v string) string {
	if v == "" {
		return Unknown
	}
	return v
}

// numericDesc orders numeric keys high to low with Unknown last.
func numericDesc(m map[string]int64) []KeyCount {
	out := make([]KeyCount, 0, len(m))
	for k, n := range m {
		out = append(out, KeyCount{Key: k, Count: n})
	}
	slices.SortFunc(out, func(a, b KeyCount) int {
		if a.Key == Unknown {
			return 1
		}
		if b.Key == Unknown {
			return -1
		}
		x, _ := strconv.ParseInt(a.Key, 10, 64)
		y, _ := strconv.ParseInt(b.Key, 10, 64)
		switch {
		case x > y:
			return -1
		case x < y:
			return 1
		default:
			// Tie-break on Key
			if a.Key < b.Key {
				return -1
			}
			if a.Key > b.Key {
				return 1
			}
			return 0
		}
	})
	return out
}

// BuildFleet describes non-banned installs active (ModeAny) in the last
// FleetWindowDays, and version adoption per day from session rows.
func BuildFleet(installs []store.Install, recent Activity, sessions []store.DayRow, adoptionDays []string, today string) Fleet {
	active := map[string]bool{}
	for _, d := range Days(AddDays(today, -(FleetWindowDays-1)), today) {
		for h := range recent[d] {
			active[h] = true
		}
	}

	var f Fleet
	versions, tiers, licensing, sdk := map[string]int64{}, map[string]int64{}, map[string]int64{}, map[string]int64{}
	for _, in := range installs {
		if in.Banned || !active[in.IDHash] {
			continue
		}
		f.ActiveInstalls++
		versions[intKey(in.Meta.AppVersionCode)]++
		tiers[strKey(in.Meta.DeviceTier)]++
		licensing[strKey(in.Meta.Licensing)]++
		sdk[intKey(in.Meta.SDKVersion)]++
	}
	f.Versions = numericDesc(versions)
	f.SDK = numericDesc(sdk)
	f.DeviceTier = sortedKeyCounts(tiers)
	f.Licensing = sortedKeyCounts(licensing)

	byDay := map[string]map[string]int64{}
	for _, s := range sessions {
		if byDay[s.Day] == nil {
			byDay[s.Day] = map[string]int64{}
		}
		byDay[s.Day][intKey(s.AppVersionCode)]++
	}
	f.Adoption = make([]DayCounts, 0, len(adoptionDays))
	for _, d := range adoptionDays {
		counts := byDay[d]
		if counts == nil {
			counts = map[string]int64{}
		}
		f.Adoption = append(f.Adoption, DayCounts{Day: d, Counts: counts})
	}
	return f
}
