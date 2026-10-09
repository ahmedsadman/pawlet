package stats

import (
	"errors"
	"testing"

	"github.com/ahmedsadman/pawlet/server/internal/store"
)

func TestBuildActivityModes(t *testing.T) {
	usage := []store.UsageRow{
		{IDHash: "a", Day: "2026-10-01", Calls: 2},
		{IDHash: "b", Day: "2026-10-01", Calls: 0}, // zero calls is not activity
	}
	sessions := []store.DayRow{{IDHash: "c", Day: "2026-10-01"}}

	classify := BuildActivity(usage, sessions, ModeClassify)
	if !classify.Active("2026-10-01", "a") || classify.Active("2026-10-01", "b") || classify.Active("2026-10-01", "c") {
		t.Fatalf("classify activity wrong: %v", classify)
	}
	anyMode := BuildActivity(usage, sessions, ModeAny)
	if !anyMode.Active("2026-10-01", "a") || !anyMode.Active("2026-10-01", "c") || anyMode.Active("2026-10-01", "b") {
		t.Fatalf("any activity wrong: %v", anyMode)
	}
}

func TestParseMode(t *testing.T) {
	for in, want := range map[string]Mode{"": ModeAny, "any": ModeAny, "classify": ModeClassify} {
		if got, err := ParseMode(in); err != nil || got != want {
			t.Errorf("ParseMode(%q) = %v, %v", in, got, err)
		}
	}
	if _, err := ParseMode("all"); !errors.Is(err, ErrBadRequest) {
		t.Fatalf("ParseMode(all) err = %v", err)
	}
}

func TestActiveSeriesRollingWindows(t *testing.T) {
	a := Activity{}
	a.mark("2026-09-01", "old")  // 30+ days before 2026-10-01: outside MAU
	a.mark("2026-09-02", "m")    // inside MAU window of 2026-10-01 (day -29)
	a.mark("2026-09-25", "w")    // inside WAU window of 2026-10-01 (day -6)
	a.mark("2026-10-01", "d")
	a.mark("2026-10-01", "w")

	got := ActiveSeries(a, []string{"2026-10-01"})
	want := ActiveCount{Day: "2026-10-01", DAU: 2, WAU: 2, MAU: 3, Stickiness: 2.0 / 3.0}
	if len(got) != 1 || got[0] != want {
		t.Fatalf("ActiveSeries() = %+v, want %+v", got, want)
	}

	empty := ActiveSeries(Activity{}, []string{"2026-10-01"})
	if empty[0].Stickiness != 0 || empty[0].MAU != 0 {
		t.Fatalf("empty series = %+v", empty)
	}
}
