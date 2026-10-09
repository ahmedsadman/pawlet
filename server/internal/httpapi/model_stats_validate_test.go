package httpapi

import (
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/ahmedsadman/pawlet/server/internal/store"
)

// validationToday is 2026-10-10 UTC, so the accepted day window is
// 2026-09-10..2026-10-11.
var validationToday = time.Date(2026, 10, 10, 23, 30, 0, 0, time.UTC)

func entry(day string) modelStatsEntry {
	return modelStatsEntry{Day: day, AppVersionCode: 21, Accepted: 40, Declined: 9, Unavailable: 1}
}

func TestValidateModelStatsAcceptsAValidBody(t *testing.T) {
	req := modelStatsRequest{Days: []modelStatsEntry{
		entry("2026-09-10"),
		{Day: "2026-10-11", AppVersionCode: 2147483647, Accepted: 100_000, Declined: 0, Unavailable: 100_000},
	}}

	got, err := validateModelStats(req, validationToday)
	if err != nil {
		t.Fatalf("validateModelStats() error = %v", err)
	}
	want := []store.ModelStatsDay{
		{Day: "2026-09-10", AppVersionCode: 21, Accepted: 40, Declined: 9, Unavailable: 1},
		{Day: "2026-10-11", AppVersionCode: 2147483647, Accepted: 100_000, Unavailable: 100_000},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("rows = %+v, want %+v", got, want)
	}
}

func TestValidateModelStatsUsesTheUTCDay(t *testing.T) {
	// 01:00 on 11 Oct in UTC+3 is still 10 Oct in UTC, so 11 Oct is "tomorrow"
	// (allowed) and 12 Oct is not.
	local := time.Date(2026, 10, 11, 1, 0, 0, 0, time.FixedZone("UTC+3", 3*3600))
	if _, err := validateModelStats(modelStatsRequest{Days: []modelStatsEntry{entry("2026-10-11")}}, local); err != nil {
		t.Errorf("2026-10-11 rejected: %v", err)
	}
	if _, err := validateModelStats(modelStatsRequest{Days: []modelStatsEntry{entry("2026-10-12")}}, local); err == nil {
		t.Error("2026-10-12 accepted, want rejected")
	}
}

func TestValidateModelStatsAcceptsThirtyOneEntries(t *testing.T) {
	days := make([]modelStatsEntry, 0, 31)
	for i := 0; i < 31; i++ {
		days = append(days, entry(validationToday.AddDate(0, 0, -i).Format(time.DateOnly)))
	}
	if _, err := validateModelStats(modelStatsRequest{Days: days}, validationToday); err != nil {
		t.Fatalf("31 entries rejected: %v", err)
	}
}

func TestValidateModelStatsRejects(t *testing.T) {
	tooMany := make([]modelStatsEntry, 0, 32)
	for i := 0; i < 32; i++ {
		e := entry("2026-10-01")
		e.AppVersionCode = int64(i + 1) // distinct, so only the count is wrong
		tooMany = append(tooMany, e)
	}
	with := func(mut func(*modelStatsEntry)) []modelStatsEntry {
		e := entry("2026-10-09")
		mut(&e)
		return []modelStatsEntry{e}
	}

	cases := []struct {
		name string
		days []modelStatsEntry
		want string
	}{
		{"no entries", nil, "want 1-31 days"},
		{"32 entries", tooMany, "want 1-31 days"},
		{"empty day", with(func(e *modelStatsEntry) { e.Day = "" }), "not YYYY-MM-DD"},
		{"single-digit month", with(func(e *modelStatsEntry) { e.Day = "2026-1-09" }), "not YYYY-MM-DD"},
		{"impossible date", with(func(e *modelStatsEntry) { e.Day = "2026-02-30" }), "not YYYY-MM-DD"},
		{"timestamp", with(func(e *modelStatsEntry) { e.Day = "2026-10-09T00:00:00Z" }), "not YYYY-MM-DD"},
		{"31 days ago", with(func(e *modelStatsEntry) { e.Day = "2026-09-09" }), "outside"},
		{"2 days ahead", with(func(e *modelStatsEntry) { e.Day = "2026-10-12" }), "outside"},
		{"version 0", with(func(e *modelStatsEntry) { e.AppVersionCode = 0 }), "appVersionCode"},
		{"version negative", with(func(e *modelStatsEntry) { e.AppVersionCode = -5 }), "appVersionCode"},
		{"version above int32", with(func(e *modelStatsEntry) { e.AppVersionCode = 2147483648 }), "appVersionCode"},
		{"accepted negative", with(func(e *modelStatsEntry) { e.Accepted = -1 }), "count out of range"},
		{"declined too big", with(func(e *modelStatsEntry) { e.Declined = 100_001 }), "count out of range"},
		{"unavailable too big", with(func(e *modelStatsEntry) { e.Unavailable = 100_001 }), "count out of range"},
		{"duplicate pair", []modelStatsEntry{entry("2026-10-09"), entry("2026-10-09")}, "duplicate"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := validateModelStats(modelStatsRequest{Days: c.days}, validationToday)
			if err == nil {
				t.Fatal("validateModelStats() error = nil, want rejection")
			}
			if !strings.Contains(err.Error(), c.want) {
				t.Fatalf("error = %q, want it to mention %q", err, c.want)
			}
		})
	}
}

func TestValidateModelStatsAllowsSameDayAcrossVersions(t *testing.T) {
	a, b := entry("2026-10-09"), entry("2026-10-09")
	b.AppVersionCode = 22
	if _, err := validateModelStats(modelStatsRequest{Days: []modelStatsEntry{a, b}}, validationToday); err != nil {
		t.Fatalf("same day, two versions rejected: %v", err)
	}
}
