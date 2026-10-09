package stats

import (
	"testing"

	"github.com/ahmedsadman/pawlet/server/internal/store"
)

func TestParseServerInfo(t *testing.T) {
	got := ParseServerInfo(map[string]string{
		store.InfoDailyPerInstall: "200", store.InfoBurstPerMin: "20", store.InfoGlobalDailyCap: "20000",
		store.InfoModels: "a, b,", store.InfoStartedAt: "1700000000", store.InfoImageTag: "abc",
	})
	if got.DailyPerInstall != 200 || got.BurstPerMin != 20 || got.GlobalDailyCap != 20000 ||
		len(got.Models) != 2 || got.Models[1] != "b" || got.StartedAt != 1700000000 || got.ImageTag != "abc" {
		t.Fatalf("ParseServerInfo() = %+v", got)
	}
	empty := ParseServerInfo(nil)
	if empty.Models == nil || len(empty.Models) != 0 {
		t.Fatalf("models should be an empty slice, got %#v", empty.Models)
	}
}

func TestBuildOverview(t *testing.T) {
	today := "2026-10-09"
	installs := []store.Install{
		install("a", "2026-10-08"),
		install("b", "2026-10-09"),
		install("c", "2026-10-01"), // previous 7d window
	}
	installs[2].Banned = true
	usage := []store.UsageRow{
		{IDHash: "a", Day: "2026-10-08", Calls: 4, Tokens: 40},
		{IDHash: "a", Day: "2026-10-09", Calls: 6, Tokens: 60},
		{IDHash: "b", Day: "2026-10-09", Calls: 2, Tokens: 20},
		{IDHash: "c", Day: "2026-10-01", Calls: 9, Tokens: 90}, // outside the 7d range
	}
	sessions := []store.DayRow{{IDHash: "b", Day: "2026-10-07"}}
	rng := Range{From: "2026-10-03", To: today}

	ov := BuildOverview(OverviewInput{
		Range: rng, Today: today, Installs: installs, Usage: usage,
		Activity:      BuildActivity(usage, sessions, ModeAny),
		CountersToday: map[string]int64{"ok": 3, "upstream_retryable": 1},
	})
	k := ov.KPIs
	if k.AttestedInstalls != 3 || k.Banned != 1 || k.NewInstalls != 2 || k.NewInstallsPrev != 1 {
		t.Fatalf("install KPIs = %+v", k)
	}
	if k.DAU != 2 || k.WAU != 2 || k.MAU != 3 {
		t.Fatalf("active KPIs = %+v", k)
	}
	if k.CallsToday != 8 || k.TokensToday != 80 {
		t.Fatalf("today KPIs = %+v", k)
	}
	if k.SuccessRateToday == nil || *k.SuccessRateToday != 0.75 {
		t.Fatalf("success rate = %v", k.SuccessRateToday)
	}
	if k.CallsPerActiveInstallDay == nil || *k.CallsPerActiveInstallDay != 4 { // 12 calls / 3 install-days
		t.Fatalf("calls per active install-day = %v", k.CallsPerActiveInstallDay)
	}
	if len(ov.Daily) != 7 {
		t.Fatalf("daily len = %d", len(ov.Daily))
	}
	last := ov.Daily[6]
	if last != (OverviewDay{Day: today, Calls: 8, Tokens: 80, ActiveInstalls: 2, NewInstalls: 1}) {
		t.Fatalf("today row = %+v", last)
	}
}

func TestBuildOverviewMessages(t *testing.T) {
	rng := Range{From: "2026-10-03", To: "2026-10-09"}
	model := []store.ModelRow{
		{IDHash: "a", Day: "2026-10-08", AppVersionCode: 20, Accepted: 3, Declined: 1},
		{IDHash: "a", Day: "2026-10-09", AppVersionCode: 20, Accepted: 2},
		{IDHash: "a", Day: "2026-10-09", AppVersionCode: 21, Accepted: 1, Unavailable: 1}, // same install-day
		{IDHash: "b", Day: "2026-10-09", AppVersionCode: 21},                              // no messages: not an active install-day
		{IDHash: "c", Day: "2026-10-01", AppVersionCode: 20, Accepted: 9},                 // outside the range
	}
	rollup := []store.ModelRollupRow{{Day: "2026-10-03", AppVersionCode: 19, Accepted: 6, Declined: 2, InstallCount: 2}}

	ov := BuildOverview(OverviewInput{
		Range: rng, Today: "2026-10-09", Model: model, ModelRollup: rollup,
		Activity: BuildActivity(nil, nil, ModeAny),
	})
	byDay := map[string]int64{}
	for _, d := range ov.Daily {
		byDay[d.Day] = d.Messages
	}
	if byDay["2026-10-03"] != 8 || byDay["2026-10-08"] != 4 || byDay["2026-10-09"] != 4 || byDay["2026-10-05"] != 0 {
		t.Fatalf("daily messages = %v", byDay)
	}
	// 16 messages over 4 install-days: a on 10-08 and 10-09, plus 2 folded into the rollup.
	if got := ov.KPIs.MessagesPerActiveInstallDay; got == nil || *got != 4 {
		t.Fatalf("messages per active install-day = %v, want 4", got)
	}

	empty := BuildOverview(OverviewInput{Range: rng, Today: "2026-10-09", Activity: BuildActivity(nil, nil, ModeAny)})
	if empty.KPIs.MessagesPerActiveInstallDay != nil {
		t.Fatalf("no model stats = %v, want nil", *empty.KPIs.MessagesPerActiveInstallDay)
	}
}
