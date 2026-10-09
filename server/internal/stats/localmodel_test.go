package stats

import (
	"math"
	"testing"

	"github.com/ahmedsadman/pawlet/server/internal/store"
)

func near(p *float64, want float64) bool { return p != nil && math.Abs(*p-want) < 1e-9 }

func TestOnDeviceRate(t *testing.T) {
	if r := OnDeviceRate(ModelCounts{Accepted: 80, Declined: 20, Unavailable: 5}); !near(r, 0.8) {
		t.Fatalf("OnDeviceRate() = %v, want 0.8 (unavailable left out)", r)
	}
	if r := OnDeviceRate(ModelCounts{Unavailable: 9}); r != nil {
		t.Fatalf("OnDeviceRate(errors only) = %v, want nil", *r)
	}
	if got := (ModelCounts{Accepted: 1, Declined: 2, Unavailable: 3}).Messages(); got != 6 {
		t.Fatalf("Messages() = %d, want 6", got)
	}
}

func TestIndexModelMergesDailyAndRollup(t *testing.T) {
	idx := indexModel(
		[]store.ModelRow{
			{IDHash: "a", Day: "2026-10-01", AppVersionCode: 20, Accepted: 8, Declined: 2},
			{IDHash: "b", Day: "2026-10-01", AppVersionCode: 20, Accepted: 2, Unavailable: 1},
			{IDHash: "a", Day: "2026-10-01", AppVersionCode: 21, Accepted: 1},
		},
		[]store.ModelRollupRow{{Day: "2026-10-01", AppVersionCode: 20, Accepted: 10, Declined: 5, InstallCount: 2}},
	)
	if got := idx.day("2026-10-01"); got != (ModelCounts{Accepted: 21, Declined: 7, Unavailable: 1}) {
		t.Fatalf("day total = %+v", got)
	}
	if got := idx["2026-10-01"][20]; got != (ModelCounts{Accepted: 20, Declined: 7, Unavailable: 1}) {
		t.Fatalf("version 20 = %+v", got)
	}
	if got := idx.day("2026-10-02"); got != (ModelCounts{}) {
		t.Fatalf("empty day = %+v", got)
	}
}

func TestRollingRatesAreWeighted(t *testing.T) {
	idx := indexModel([]store.ModelRow{
		{IDHash: "a", Day: "2026-09-26", AppVersionCode: 20, Accepted: 18, Declined: 2}, // rate 0.9 on 20 messages, before the range
		{IDHash: "a", Day: "2026-10-01", AppVersionCode: 20, Accepted: 1, Declined: 9},  // rate 0.1 on 10 messages
	}, nil)
	got := rollingRates(idx, Days("2026-10-01", "2026-10-08"))
	if len(got) != 8 {
		t.Fatalf("len = %d", len(got))
	}
	// Window 09-25..10-01 reaches back before the range: 19 ÷ 30, not the
	// mean of the two daily rates (0.5).
	if got[0].Day != "2026-10-01" || !near(got[0].Rate, 19.0/30.0) {
		t.Fatalf("10-01 = %+v", got[0])
	}
	if !near(got[1].Rate, 19.0/30.0) { // 09-26..10-02 still holds both days
		t.Fatalf("10-02 = %+v", got[1])
	}
	if !near(got[2].Rate, 0.1) { // 09-27..10-03: 09-26 has left the window
		t.Fatalf("10-03 = %+v", got[2])
	}
	if got[7].Rate != nil { // 10-02..10-08 is empty
		t.Fatalf("10-08 = %v, want nil", *got[7].Rate)
	}
}

func TestVersionMarkers(t *testing.T) {
	row := func(day string, version, accepted, declined, unavailable int64) store.ModelRow {
		return store.ModelRow{IDHash: "a", Day: day, AppVersionCode: version, Accepted: accepted, Declined: declined, Unavailable: unavailable}
	}
	idx := indexModel([]store.ModelRow{
		row("2026-10-01", 20, 15, 4, 0), // 19 messages: too few to count
		row("2026-10-02", 20, 17, 2, 1), // 20 (errors count as messages): baseline 20, no marker
		row("2026-10-03", 20, 10, 0, 0), // 50/50 split: no majority
		row("2026-10-03", 21, 10, 0, 0), //
		row("2026-10-04", 20, 5, 0, 0),  // v21 has 25 of 30: marker
		row("2026-10-04", 21, 20, 5, 0), //
		row("2026-10-05", 21, 30, 0, 0), // same version: no marker
		row("2026-10-06", 20, 40, 0, 0), // back to v20 (a rollback): marker
	}, nil)
	got := versionMarkers(idx, Days("2026-10-01", "2026-10-06"))
	want := []VersionMarker{{Day: "2026-10-04", AppVersionCode: 21}, {Day: "2026-10-06", AppVersionCode: 20}}
	if len(got) != len(want) {
		t.Fatalf("versionMarkers() = %+v, want %+v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("versionMarkers() = %+v, want %+v", got, want)
		}
	}

	empty := versionMarkers(modelIndex{}, Days("2026-10-01", "2026-10-06"))
	if empty == nil || len(empty) != 0 {
		t.Fatalf("no data = %#v, want an empty, non-nil slice", empty)
	}
}
