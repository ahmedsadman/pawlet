package stats

import (
	"testing"
	"time"

	"github.com/ahmedsadman/pawlet/server/internal/store"
)

func install(hash, firstSeenDay string) store.Install {
	t, _ := time.Parse(DayLayout, firstSeenDay)
	return store.Install{IDHash: hash, FirstSeen: t.Add(9 * time.Hour), LastSeen: t.Add(9 * time.Hour)}
}

func TestCohorts(t *testing.T) {
	today := "2026-10-14" // Wednesday; current week starts 2026-10-12
	installs := []store.Install{
		install("a", "2026-10-06"), // cohort 2026-10-05
		install("b", "2026-10-08"), // cohort 2026-10-05
		install("c", "2026-10-12"), // cohort 2026-10-12
		install("z", "2026-01-01"), // older than the window: ignored
	}
	a := Activity{}
	a.mark("2026-10-06", "a")
	a.mark("2026-10-08", "b")
	a.mark("2026-10-13", "a") // a returns in week 1
	a.mark("2026-10-12", "c")

	got := Cohorts(installs, a, today, 2)
	if len(got) != 2 {
		t.Fatalf("len = %d, want 2", len(got))
	}
	first := got[0]
	if first.WeekStart != "2026-10-05" || first.Size != 2 || len(first.Retention) != CohortWeeks {
		t.Fatalf("first cohort = %+v", first)
	}
	if *first.Retention[0] != 1.0 || *first.Retention[1] != 0.5 || first.Retention[2] != nil {
		t.Fatalf("first retention = %v, %v, %v", *first.Retention[0], *first.Retention[1], first.Retention[2])
	}
	second := got[1]
	if second.WeekStart != "2026-10-12" || second.Size != 1 || *second.Retention[0] != 1.0 || second.Retention[1] != nil {
		t.Fatalf("second cohort = %+v", second)
	}
}

func TestCohortsEmptyWeekHasNilRetention(t *testing.T) {
	got := Cohorts(nil, Activity{}, "2026-10-14", 1)
	if len(got) != 1 || got[0].Size != 0 || got[0].Retention[0] != nil {
		t.Fatalf("Cohorts(empty) = %+v", got)
	}
}
