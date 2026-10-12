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
	days := []store.DayRow{
		{IDHash: "c", Day: "2026-10-01", Session: true},
		{IDHash: "d", Day: "2026-10-01", Alive: true},
		{IDHash: "e", Day: "2026-10-01", Opened: true, Alive: true},
	}

	classify := BuildActivity(usage, days, ModeClassify)
	for h, want := range map[string]bool{"a": true, "b": false, "c": false, "d": false, "e": false} {
		if classify.Active("2026-10-01", h) != want {
			t.Errorf("classify %s = %v, want %v", h, !want, want)
		}
	}
	anyMode := BuildActivity(usage, days, ModeAny)
	for h, want := range map[string]bool{"a": true, "b": false, "c": true, "d": true, "e": true} {
		if anyMode.Active("2026-10-01", h) != want {
			t.Errorf("any %s = %v, want %v", h, !want, want)
		}
	}
	// A session day counts as opened: sessions are only minted in the
	// foreground, and builds without heartbeats report nothing else.
	opened := BuildActivity(usage, days, ModeOpened)
	for h, want := range map[string]bool{"a": false, "b": false, "c": true, "d": false, "e": true} {
		if opened.Active("2026-10-01", h) != want {
			t.Errorf("opened %s = %v, want %v", h, !want, want)
		}
	}
}

func TestParseMode(t *testing.T) {
	for in, want := range map[string]Mode{
		"": ModeAny, "any": ModeAny, "opened": ModeOpened, "classify": ModeClassify,
	} {
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
	a.mark("2026-09-01", "old") // 30+ days before 2026-10-01: outside MAU
	a.mark("2026-09-02", "m")   // inside MAU window of 2026-10-01 (day -29)
	a.mark("2026-09-25", "w")   // inside WAU window of 2026-10-01 (day -6)
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
