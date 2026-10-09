package stats

import (
	"errors"
	"testing"
	"time"

	"github.com/ahmedsadman/pawlet/server/internal/store"
)

func fixtureInstalls() ([]store.Install, []store.UsageRow) {
	day := func(s string) time.Time { t, _ := time.Parse(DayLayout, s); return t.Add(10 * time.Hour) }
	installs := []store.Install{
		{
			IDHash: "aaaa", FirstSeen: day("2026-09-01"), LastSeen: day("2026-10-09"),
			Meta: store.InstallMeta{AppVersionCode: 18, DeviceTier: "STRONG", Licensing: "LICENSED", SDKVersion: 34},
		},
		{IDHash: "bbbb", FirstSeen: day("2026-09-02"), LastSeen: day("2026-09-10")}, // dormant
		{IDHash: "cccc", FirstSeen: day("2026-09-03"), LastSeen: day("2026-09-05"), Banned: true, BanReason: "abuse"},
	}
	usage := []store.UsageRow{
		{IDHash: "aaaa", Day: "2026-10-09", Calls: 4, Tokens: 40},
		{IDHash: "aaaa", Day: "2026-10-05", Calls: 200, Tokens: 900},
		{IDHash: "aaaa", Day: "2026-09-01", Calls: 10, Tokens: 100},
		{IDHash: "bbbb", Day: "2026-09-20", Calls: 1, Tokens: 5}, // last activity 19 days ago
		{IDHash: "zzzz", Day: "2026-10-09", Calls: 9},            // unknown install: ignored
	}
	return installs, usage
}

func TestBuildInstallRows(t *testing.T) {
	installs, usage := fixtureInstalls()
	rows := BuildInstallRows(installs, usage, "2026-10-09", 200)
	if len(rows) != 3 {
		t.Fatalf("len = %d", len(rows))
	}
	a := rows[0]
	if a.CallsToday != 4 || a.Calls7d != 204 || a.CallsTotal != 214 || a.TokensTotal != 1040 || a.QuotaHitDays != 1 {
		t.Fatalf("a counts = %+v", a)
	}
	if a.AppVersionCode == nil || *a.AppVersionCode != 18 || a.DeviceTier == nil || *a.DeviceTier != "STRONG" || a.Dormant {
		t.Fatalf("a meta/dormant = %+v", a)
	}
	b := rows[1]
	if b.LastActiveDay != "2026-09-20" || !b.Dormant || b.AppVersionCode != nil || b.DeviceTier != nil {
		t.Fatalf("b = %+v", b)
	}
	c := rows[2]
	if !c.Banned || c.Dormant || c.BanReason != "abuse" {
		t.Fatalf("c = %+v (banned installs are never dormant)", c)
	}
}

func TestDormancyBoundary(t *testing.T) {
	day := func(s string) time.Time { t, _ := time.Parse(DayLayout, s); return t }
	today := "2026-10-09"

	// Exactly 14 days ago: not dormant
	installs := []store.Install{{IDHash: "a", FirstSeen: day("2026-09-01"), LastSeen: day("2026-09-25")}}
	usage := []store.UsageRow{{IDHash: "a", Day: "2026-09-25", Calls: 1}}
	rows := BuildInstallRows(installs, usage, today, 0)
	if rows[0].Dormant {
		t.Fatalf("14 days ago should not be dormant: %+v", rows[0])
	}

	// 15 days ago: dormant
	installs = []store.Install{{IDHash: "b", FirstSeen: day("2026-09-01"), LastSeen: day("2026-09-24")}}
	usage = []store.UsageRow{{IDHash: "b", Day: "2026-09-24", Calls: 1}}
	rows = BuildInstallRows(installs, usage, today, 0)
	if !rows[0].Dormant {
		t.Fatalf("15 days ago should be dormant: %+v", rows[0])
	}
}

func TestQueryInstalls(t *testing.T) {
	installs, usage := fixtureInstalls()
	rows := BuildInstallRows(installs, usage, "2026-10-09", 200)

	page, err := QueryInstalls(rows, InstallQuery{})
	if err != nil || page.Total != 3 || page.Page != 1 || page.PageSize != DefaultPageSize || page.Rows[0].Hash != "aaaa" {
		t.Fatalf("default query = %+v, %v (want lastSeen desc)", page, err)
	}

	page, _ = QueryInstalls(rows, InstallQuery{Sort: "tokensTotal", Order: "asc"})
	if page.Rows[0].Hash != "cccc" || page.Rows[2].Hash != "aaaa" {
		t.Fatalf("tokensTotal asc = %v", hashes(page.Rows))
	}

	for status, want := range map[string]string{"active": "aaaa", "dormant": "bbbb", "banned": "cccc"} {
		page, _ = QueryInstalls(rows, InstallQuery{Status: status})
		if page.Total != 1 || page.Rows[0].Hash != want {
			t.Errorf("status %s = %v", status, hashes(page.Rows))
		}
	}

	page, _ = QueryInstalls(rows, InstallQuery{Q: "BB"})
	if page.Total != 1 || page.Rows[0].Hash != "bbbb" {
		t.Fatalf("prefix search = %v", hashes(page.Rows))
	}

	page, _ = QueryInstalls(rows, InstallQuery{PageSize: 2, Page: 2})
	if page.Total != 3 || len(page.Rows) != 1 {
		t.Fatalf("page 2 = %+v", page)
	}
	page, _ = QueryInstalls(rows, InstallQuery{PageSize: 2, Page: 9})
	if len(page.Rows) != 0 {
		t.Fatalf("past last page = %+v", page)
	}

	// Overflow regression: huge page numbers should not panic
	for _, hugePage := range []int{1<<62 + 1, 9223372036854775807} {
		page, _ = QueryInstalls(rows, InstallQuery{PageSize: 2, Page: hugePage})
		if len(page.Rows) != 0 || page.Total != 3 {
			t.Fatalf("huge page %d = %+v", hugePage, page)
		}
	}

	badQueries := []InstallQuery{
		{Sort: "nope"},
		{Order: "up"},
		{Status: "gone"},
		// Replaced by the message sorts.
		{Sort: "callsToday"},
		{Sort: "calls7d"},
		{Sort: "callsTotal"},
	}
	for _, bad := range badQueries {
		if _, err := QueryInstalls(rows, bad); !errors.Is(err, ErrBadRequest) {
			t.Errorf("QueryInstalls(%+v) err = %v", bad, err)
		}
	}
}

func hashes(rows []InstallRow) []string {
	out := make([]string, len(rows))
	for i, r := range rows {
		out[i] = r.Hash
	}
	return out
}

func TestInstallDaily(t *testing.T) {
	usage := []store.UsageRow{{IDHash: "a", Day: "2026-10-02", Calls: 3, Tokens: 30}}
	got := InstallDaily("2026-10-01", "2026-10-03", usage, []string{"2026-10-01", "2026-10-02"}, nil, false)
	want := []DetailDay{
		{Day: "2026-10-01", Session: true},
		{Day: "2026-10-02", Calls: 3, Tokens: 30, Session: true},
		{Day: "2026-10-03"},
	}
	if len(got) != len(want) {
		t.Fatalf("InstallDaily() = %+v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("InstallDaily() = %+v, want %+v", got, want)
		}
	}
	if len(InstallDaily("2026-10-05", "2026-10-03", nil, nil, nil, false)) != 1 {
		t.Fatal("first seen after today should clamp to one day")
	}
}

func TestApplyModelStats(t *testing.T) {
	installs, usage := fixtureInstalls()
	rows := BuildInstallRows(installs, usage, "2026-10-09", 200)
	ApplyModelStats(rows, []store.ModelRow{
		{IDHash: "aaaa", Day: "2026-10-09", AppVersionCode: 18, Accepted: 5, Declined: 1},
		{IDHash: "aaaa", Day: "2026-10-09", AppVersionCode: 19, Accepted: 1},  // same day, newer version
		{IDHash: "aaaa", Day: "2026-10-02", AppVersionCode: 18, Accepted: 20}, // before the 7-day window
		{IDHash: "zzzz", Day: "2026-10-09", AppVersionCode: 18, Accepted: 9},  // unknown install: ignored
	}, map[string]int64{"aaaa": 100, "cccc": 7}, "2026-10-09")

	a, b, c := rows[0], rows[1], rows[2]
	if a.MessagesToday != 7 || a.Messages7d != 7 || a.MessagesTotal != 127 || !a.HasModelStats {
		t.Fatalf("a = %+v", a)
	}
	if b.MessagesTotal != 0 || b.HasModelStats {
		t.Fatalf("b = %+v (no model stats)", b)
	}
	if c.MessagesToday != 0 || c.MessagesTotal != 7 || !c.HasModelStats {
		t.Fatalf("c = %+v (archived only)", c)
	}

	page, err := QueryInstalls(rows, InstallQuery{Sort: "messagesTotal"})
	if err != nil || hashes(page.Rows)[0] != "aaaa" || hashes(page.Rows)[1] != "cccc" || hashes(page.Rows)[2] != "bbbb" {
		t.Fatalf("messagesTotal desc = %v, %v", hashes(page.Rows), err)
	}
	for _, key := range []string{"messagesToday", "messages7d"} {
		page, err = QueryInstalls(rows, InstallQuery{Sort: key, Order: "asc"})
		if err != nil || page.Rows[2].Hash != "aaaa" {
			t.Fatalf("%s asc = %v, %v", key, hashes(page.Rows), err)
		}
	}
}

func TestInstallDailyMessages(t *testing.T) {
	model := []store.ModelRow{
		{IDHash: "a", Day: "2026-07-11", AppVersionCode: 20, Accepted: 5},                 // 90 days back: outside the window
		{IDHash: "a", Day: "2026-10-08", AppVersionCode: 20, Accepted: 3, Declined: 1},    //
		{IDHash: "a", Day: "2026-10-08", AppVersionCode: 21, Accepted: 1, Unavailable: 1}, // same day, summed
	}
	got := InstallDaily("2026-07-10", "2026-10-09", nil, nil, model, true)
	byDay := map[string]DetailDay{}
	for _, d := range got {
		byDay[d.Day] = d
	}
	if d := byDay["2026-07-11"]; d.Messages != nil || d.OnDevice != nil {
		t.Fatalf("outside the 90-day window = %+v, want null", d)
	}
	if d := byDay["2026-07-12"]; d.Messages == nil || *d.Messages != 0 || d.OnDevice == nil || *d.OnDevice != 0 {
		t.Fatalf("first day in the window = %+v, want 0", d)
	}
	if d := byDay["2026-10-08"]; d.Messages == nil || *d.Messages != 6 || *d.OnDevice != 4 {
		t.Fatalf("10-08 = %+v, want 6 messages, 4 on device", d)
	}

	for _, d := range InstallDaily("2026-10-01", "2026-10-09", nil, nil, nil, false) {
		if d.Messages != nil || d.OnDevice != nil {
			t.Fatalf("install without model stats = %+v, want null", d)
		}
	}
}
