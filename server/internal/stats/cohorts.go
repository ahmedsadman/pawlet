package stats

import "github.com/ahmedsadman/pawlet/server/internal/store"

// CohortWeeks is how many weeks each cohort row tracks: week 0 to week 12.
const CohortWeeks = 13

// Cohort is the installs first seen in one ISO week and the share of them
// active in each later week. A week that has not started yet is nil.
type Cohort struct {
	WeekStart string     `json:"weekStart"`
	Size      int        `json:"size"`
	Retention []*float64 `json:"retention"`
}

// Cohorts builds the last count weekly cohorts ending with today's week.
// Activity must reach from the oldest cohort's Monday through today.
func Cohorts(installs []store.Install, a Activity, today string, count int) []Cohort {
	oldest := AddDays(WeekStart(today), -7*(count-1))
	members := make(map[string][]string)
	for _, in := range installs {
		week := WeekStart(in.FirstSeen.UTC().Format(DayLayout))
		if week >= oldest {
			members[week] = append(members[week], in.IDHash)
		}
	}

	out := make([]Cohort, 0, count)
	for i := 0; i < count; i++ {
		start := AddDays(oldest, 7*i)
		c := Cohort{WeekStart: start, Size: len(members[start]), Retention: make([]*float64, CohortWeeks)}
		for n := 0; n < CohortWeeks && c.Size > 0; n++ {
			weekFrom := AddDays(start, 7*n)
			if weekFrom > today {
				break
			}
			weekTo := AddDays(weekFrom, 6)
			if weekTo > today {
				weekTo = today
			}
			active := 0
			for _, h := range members[start] {
				if a.activeBetween(h, weekFrom, weekTo) {
					active++
				}
			}
			share := float64(active) / float64(c.Size)
			c.Retention[n] = &share
		}
		out = append(out, c)
	}
	return out
}
