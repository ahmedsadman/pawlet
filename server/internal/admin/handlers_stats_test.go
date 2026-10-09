package admin

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/ahmedsadman/pawlet/server/internal/store"
)

var (
	hashA = strings.Repeat("a", 64)
	hashB = strings.Repeat("b", 64)
)

func seedStats(t *testing.T, st *store.Store) {
	t.Helper()
	ctx := context.Background()
	if err := st.TouchInstall(ctx, hashA, testNow.Add(-48*time.Hour), store.InstallMeta{AppVersionCode: 18, DeviceTier: "STRONG"}); err != nil {
		t.Fatal(err)
	}
	if err := st.TouchInstall(ctx, hashA, testNow, store.InstallMeta{AppVersionCode: 18, DeviceTier: "STRONG"}); err != nil {
		t.Fatal(err)
	}
	if err := st.TouchInstall(ctx, hashB, testNow.Add(-40*24*time.Hour), store.InstallMeta{}); err != nil {
		t.Fatal(err)
	}
	if err := st.AddUsage(ctx, []store.UsageDelta{
		{IDHash: hashA, Day: "2026-10-09", Calls: 5, Tokens: 500},
		{IDHash: hashA, Day: "2026-10-07", Calls: 2, Tokens: 200},
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.AddCounters(ctx, []store.CounterDelta{
		{Day: "2026-10-09", Metric: "classify_outcome", Key: "ok", Count: 5},
		{Day: "2026-10-09", Metric: "classify_latency_ms", Key: "2000", Count: 5},
		{Day: "2026-10-09", Metric: "model", Key: "m1", Count: 5},
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.PutServerInfo(ctx, map[string]string{store.InfoDailyPerInstall: "200", store.InfoModels: "m1"}); err != nil {
		t.Fatal(err)
	}
}

func getJSON(t *testing.T, e *testEnv, path string, cookie *http.Cookie, into any) int {
	t.Helper()
	rec := e.do(http.MethodGet, path, "", cookie)
	if rec.Code == http.StatusOK {
		if err := json.NewDecoder(rec.Body).Decode(into); err != nil {
			t.Fatalf("decode %s: %v", path, err)
		}
	}
	return rec.Code
}

func TestStatsRoutesRequireSession(t *testing.T) {
	e := newTestEnv(t)
	for _, p := range []string{
		"/api/overview", "/api/installs", "/api/installs/" + hashA,
		"/api/engagement", "/api/reliability", "/api/fleet",
	} {
		if rec := e.do(http.MethodGet, p, "", nil); rec.Code != http.StatusUnauthorized {
			t.Errorf("GET %s without session = %d", p, rec.Code)
		}
	}
}

func TestOverviewHandler(t *testing.T) {
	e := newTestEnv(t)
	seedStats(t, e.store)
	cookie := e.login(t)

	var got struct {
		Range struct{ From, To string } `json:"range"`
		KPIs  struct {
			AttestedInstalls int   `json:"attestedInstalls"`
			CallsToday       int64 `json:"callsToday"`
			DAU              int   `json:"dau"`
		} `json:"kpis"`
		Daily  []json.RawMessage `json:"daily"`
		Server struct {
			DailyPerInstall int      `json:"dailyPerInstall"`
			Models          []string `json:"models"`
		} `json:"server"`
		CollectingSince struct {
			Sessions *string `json:"sessions"`
			Counters *string `json:"counters"`
		} `json:"collectingSince"`
	}
	if code := getJSON(t, e, "/api/overview?range=7d", cookie, &got); code != http.StatusOK {
		t.Fatalf("overview = %d", code)
	}
	if got.Range.From != "2026-10-03" || got.Range.To != "2026-10-09" || len(got.Daily) != 7 {
		t.Fatalf("range/daily = %+v %d", got.Range, len(got.Daily))
	}
	if got.KPIs.AttestedInstalls != 2 || got.KPIs.CallsToday != 5 || got.KPIs.DAU != 1 {
		t.Fatalf("kpis = %+v", got.KPIs)
	}
	if got.Server.DailyPerInstall != 200 || len(got.Server.Models) != 1 {
		t.Fatalf("server = %+v", got.Server)
	}
	if got.CollectingSince.Counters == nil || *got.CollectingSince.Counters != "2026-10-09" {
		t.Fatalf("collectingSince = %+v", got.CollectingSince)
	}
	if rec := e.do(http.MethodGet, "/api/overview?range=1y", "", cookie); rec.Code != http.StatusBadRequest {
		t.Fatalf("bad range = %d", rec.Code)
	}
}

func TestInstallsHandlers(t *testing.T) {
	e := newTestEnv(t)
	seedStats(t, e.store)
	cookie := e.login(t)

	var page struct {
		Rows []struct {
			Hash    string `json:"hash"`
			Dormant bool   `json:"dormant"`
		} `json:"rows"`
		Total    int `json:"total"`
		PageSize int `json:"pageSize"`
	}
	if code := getJSON(t, e, "/api/installs?status=dormant", cookie, &page); code != http.StatusOK {
		t.Fatalf("installs = %d", code)
	}
	if page.Total != 1 || page.Rows[0].Hash != hashB || !page.Rows[0].Dormant || page.PageSize != 50 {
		t.Fatalf("dormant page = %+v", page)
	}
	if rec := e.do(http.MethodGet, "/api/installs?sort=bogus", "", cookie); rec.Code != http.StatusBadRequest {
		t.Fatalf("bad sort = %d", rec.Code)
	}
	// Bad page parameter
	if rec := e.do(http.MethodGet, "/api/installs?page=abc", "", cookie); rec.Code != http.StatusBadRequest {
		t.Fatalf("page=abc = %d, want 400", rec.Code)
	}
	if rec := e.do(http.MethodGet, "/api/installs?page=0", "", cookie); rec.Code != http.StatusBadRequest {
		t.Fatalf("page=0 = %d, want 400", rec.Code)
	}
	if rec := e.do(http.MethodGet, "/api/installs?page=999999999999999999999", "", cookie); rec.Code != http.StatusBadRequest {
		t.Fatalf("page overflow = %d, want 400", rec.Code)
	}

	var detail struct {
		Install struct {
			Hash       string `json:"hash"`
			CallsTotal int64  `json:"callsTotal"`
		} `json:"install"`
		Daily []struct {
			Day     string `json:"day"`
			Session bool   `json:"session"`
		} `json:"daily"`
	}
	if code := getJSON(t, e, "/api/installs/"+hashA, cookie, &detail); code != http.StatusOK {
		t.Fatalf("detail = %d", code)
	}
	if detail.Install.CallsTotal != 7 || len(detail.Daily) != 3 || !detail.Daily[2].Session {
		t.Fatalf("detail = %+v", detail)
	}
	if rec := e.do(http.MethodGet, "/api/installs/"+strings.Repeat("c", 64), "", cookie); rec.Code != http.StatusNotFound {
		t.Fatalf("unknown install = %d", rec.Code)
	}
	if rec := e.do(http.MethodGet, "/api/installs/NOT-A-HASH", "", cookie); rec.Code != http.StatusBadRequest {
		t.Fatalf("malformed hash = %d", rec.Code)
	}
}

func TestBanAndUnban(t *testing.T) {
	e := newTestEnv(t)
	seedStats(t, e.store)
	cookie := e.login(t)
	ctx := context.Background()

	if rec := e.do(http.MethodPost, "/api/installs/"+hashA+"/ban", `{"reason":"  "}`, cookie); rec.Code != http.StatusBadRequest {
		t.Fatalf("blank reason = %d", rec.Code)
	}
	if rec := e.do(http.MethodPost, "/api/installs/"+hashA+"/ban", `{"reason":"`+strings.Repeat("x", 201)+`"}`, cookie); rec.Code != http.StatusBadRequest {
		t.Fatalf("long reason = %d", rec.Code)
	}
	if rec := e.do(http.MethodPost, "/api/installs/"+strings.Repeat("c", 64)+"/ban", `{"reason":"x"}`, cookie); rec.Code != http.StatusNotFound {
		t.Fatalf("ban unknown = %d", rec.Code)
	}
	if rec := e.do(http.MethodPost, "/api/installs/"+hashA+"/ban", `{"reason":"scripted calls"}`, cookie); rec.Code != http.StatusNoContent {
		t.Fatalf("ban = %d", rec.Code)
	}
	in, _ := e.store.Install(ctx, hashA)
	if !in.Banned || in.BanReason != "scripted calls" {
		t.Fatalf("after ban = %+v", in)
	}
	if rec := e.do(http.MethodPost, "/api/installs/"+hashA+"/unban", `{}`, cookie); rec.Code != http.StatusNoContent {
		t.Fatalf("unban = %d", rec.Code)
	}
	in, _ = e.store.Install(ctx, hashA)
	if in.Banned {
		t.Fatalf("after unban = %+v", in)
	}
	if rec := e.do(http.MethodPost, "/api/installs/"+hashA+"/ban", `{"reason":"x"}`, nil); rec.Code != http.StatusUnauthorized {
		t.Fatalf("ban without session = %d", rec.Code)
	}
	// Unban unknown hash
	if rec := e.do(http.MethodPost, "/api/installs/"+strings.Repeat("d", 64)+"/unban", `{}`, cookie); rec.Code != http.StatusNotFound {
		t.Fatalf("unban unknown = %d, want 404", rec.Code)
	}
	// Ban with malformed JSON
	if rec := e.do(http.MethodPost, "/api/installs/"+hashA+"/ban", `{bad`, cookie); rec.Code != http.StatusBadRequest {
		t.Fatalf("ban malformed JSON = %d, want 400", rec.Code)
	}
	// Ban with cross-origin
	req := httptest.NewRequest(http.MethodPost, "/api/installs/"+hashA+"/ban", strings.NewReader(`{"reason":"x"}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Origin", "https://evil.test")
	req.AddCookie(cookie)
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("ban cross-origin = %d, want 403", rec.Code)
	}
}

func TestEngagementReliabilityFleetHandlers(t *testing.T) {
	e := newTestEnv(t)
	seedStats(t, e.store)
	cookie := e.login(t)

	var eng struct {
		Mode    string            `json:"mode"`
		Daily   []json.RawMessage `json:"daily"`
		Cohorts []struct {
			Retention []*float64 `json:"retention"`
		} `json:"cohorts"`
		Dormant int `json:"dormant"`
	}
	if code := getJSON(t, e, "/api/engagement?range=7d&active=classify", cookie, &eng); code != http.StatusOK {
		t.Fatalf("engagement = %d", code)
	}
	if eng.Mode != "classify" || len(eng.Daily) != 7 || len(eng.Cohorts) != 12 || len(eng.Cohorts[0].Retention) != 13 || eng.Dormant != 1 {
		t.Fatalf("engagement = %+v", eng)
	}
	if rec := e.do(http.MethodGet, "/api/engagement?active=bogus", "", cookie); rec.Code != http.StatusBadRequest {
		t.Fatalf("bad mode = %d", rec.Code)
	}

	var rel struct {
		Latency []struct {
			P50 *float64 `json:"p50"`
		} `json:"latency"`
		Models []struct{ Key string } `json:"models"`
	}
	if code := getJSON(t, e, "/api/reliability?range=7d", cookie, &rel); code != http.StatusOK {
		t.Fatalf("reliability = %d", code)
	}
	if len(rel.Latency) != 7 || rel.Latency[6].P50 == nil || *rel.Latency[6].P50 != 1500 || rel.Models[0].Key != "m1" {
		t.Fatalf("reliability = %+v", rel)
	}
	// Bad range
	if rec := e.do(http.MethodGet, "/api/reliability?range=1y", "", cookie); rec.Code != http.StatusBadRequest {
		t.Fatalf("reliability bad range = %d, want 400", rec.Code)
	}

	var fleet struct {
		ActiveInstalls int `json:"activeInstalls"`
		Versions       []struct {
			Key   string `json:"key"`
			Count int    `json:"count"`
		} `json:"versions"`
		Adoption []json.RawMessage `json:"adoption"`
	}
	if code := getJSON(t, e, "/api/fleet", cookie, &fleet); code != http.StatusOK {
		t.Fatalf("fleet = %d", code)
	}
	if fleet.ActiveInstalls != 1 || fleet.Versions[0].Key != "18" || len(fleet.Adoption) != 90 {
		t.Fatalf("fleet = %+v", fleet)
	}
}

// execSQL writes fixture rows straight to the test database. The admin only
// reads model stats, so the store has no method to write them through.
func execSQL(t *testing.T, e *testEnv, q string, args ...any) {
	t.Helper()
	db, err := sql.Open("sqlite", "file:"+e.dbPath)
	if err != nil {
		t.Fatalf("open fixture db: %v", err)
	}
	defer func() { _ = db.Close() }()
	if _, err := db.ExecContext(context.Background(), q, args...); err != nil {
		t.Fatalf("fixture %q: %v", q, err)
	}
}

// seedModelStats adds local-model counts on top of seedStats (testNow is
// 2026-10-09). The rollup row sits inside the 7-day range on purpose: the
// handlers must merge it whatever its age.
func seedModelStats(t *testing.T, e *testEnv) {
	t.Helper()
	execSQL(t, e, `INSERT INTO model_stats_daily
	    (id_hash, day, app_version_code, accepted, declined, unavailable)
	  VALUES (?, '2026-10-09', 18, 8, 2, 1), (?, '2026-10-07', 18, 4, 1, 0)`, hashA, hashA)
	execSQL(t, e, `INSERT INTO model_stats_rollup
	    (day, app_version_code, accepted, declined, unavailable, install_count)
	  VALUES ('2026-10-03', 17, 8, 2, 0, 2)`)
	execSQL(t, e, `UPDATE installs SET messages_archived = 50 WHERE id_hash = ?`, hashA)
}

func TestReliabilityLocalModel(t *testing.T) {
	e := newTestEnv(t)
	seedStats(t, e.store)
	seedModelStats(t, e)
	// In the previous 7-day period, and inside the first range day's window.
	execSQL(t, e, `INSERT INTO model_stats_daily
	    (id_hash, day, app_version_code, accepted, declined, unavailable)
	  VALUES (?, '2026-09-30', 18, 1, 1, 0)`, hashA)
	cookie := e.login(t)

	type localModel struct {
		Accepted    int64    `json:"accepted"`
		Declined    int64    `json:"declined"`
		Unavailable int64    `json:"unavailable"`
		Rate        *float64 `json:"rate"`
		PrevRate    *float64 `json:"prevRate"`
		Daily       []struct {
			Day      string   `json:"day"`
			Accepted int64    `json:"accepted"`
			Rate     *float64 `json:"rate"`
		} `json:"daily"`
		Rolling7 []struct {
			Day  string   `json:"day"`
			Rate *float64 `json:"rate"`
		} `json:"rolling7"`
		VersionMarkers []json.RawMessage `json:"versionMarkers"`
	}
	var rel struct {
		LocalModel localModel `json:"localModel"`
	}
	if code := getJSON(t, e, "/api/reliability?range=7d", cookie, &rel); code != http.StatusOK {
		t.Fatalf("reliability = %d", code)
	}
	lm := rel.LocalModel
	// 10-03 rollup {8,2,0} + 10-07 {4,1,0} + 10-09 {8,2,1}.
	if lm.Accepted != 20 || lm.Declined != 5 || lm.Unavailable != 1 || lm.Rate == nil || *lm.Rate != 0.8 {
		t.Fatalf("totals = %+v", lm)
	}
	if lm.PrevRate == nil || *lm.PrevRate != 0.5 {
		t.Fatalf("prevRate = %v, want 0.5", lm.PrevRate)
	}
	if len(lm.Daily) != 7 || lm.Daily[0].Day != "2026-10-03" || lm.Daily[0].Accepted != 8 ||
		lm.Daily[5].Rate != nil || lm.Daily[6].Rate == nil || *lm.Daily[6].Rate != 0.8 {
		t.Fatalf("daily = %+v", lm.Daily)
	}
	// 10-03's window (09-27..10-03) reaches the 09-30 row: 9 ÷ 12.
	if len(lm.Rolling7) != 7 || lm.Rolling7[0].Rate == nil || *lm.Rolling7[0].Rate != 0.75 {
		t.Fatalf("rolling7 = %+v", lm.Rolling7)
	}
	if lm.VersionMarkers == nil || len(lm.VersionMarkers) != 0 {
		t.Fatalf("versionMarkers = %v, want [] (not null)", lm.VersionMarkers)
	}

	var all struct {
		LocalModel localModel `json:"localModel"`
	}
	if code := getJSON(t, e, "/api/reliability?range=all", cookie, &all); code != http.StatusOK {
		t.Fatalf("reliability all = %d", code)
	}
	if all.LocalModel.PrevRate != nil {
		t.Fatalf("range=all prevRate = %v, want nil", *all.LocalModel.PrevRate)
	}
}

func TestRangeAllReachesModelStats(t *testing.T) {
	e := newTestEnv(t)
	seedStats(t, e.store)
	seedModelStats(t, e)
	// Older than every other source (hashB was first seen on 2026-08-30).
	execSQL(t, e, `INSERT INTO model_stats_rollup
	    (day, app_version_code, accepted, declined, unavailable, install_count)
	  VALUES ('2026-08-01', 16, 3, 1, 0, 1)`)
	cookie := e.login(t)

	var rel struct {
		Range      struct{ From, To string } `json:"range"`
		LocalModel struct {
			Accepted int64    `json:"accepted"`
			PrevRate *float64 `json:"prevRate"`
		} `json:"localModel"`
	}
	if code := getJSON(t, e, "/api/reliability?range=all", cookie, &rel); code != http.StatusOK {
		t.Fatalf("reliability all = %d", code)
	}
	if rel.Range.From != "2026-08-01" || rel.LocalModel.Accepted != 23 || rel.LocalModel.PrevRate != nil {
		t.Fatalf("range=all = %+v", rel)
	}
}

func TestInstallsMessages(t *testing.T) {
	e := newTestEnv(t)
	seedStats(t, e.store)
	seedModelStats(t, e)
	cookie := e.login(t)

	var page struct {
		Rows []struct {
			Hash          string `json:"hash"`
			MessagesToday int64  `json:"messagesToday"`
			Messages7d    int64  `json:"messages7d"`
			MessagesTotal int64  `json:"messagesTotal"`
			HasModelStats bool   `json:"hasModelStats"`
		} `json:"rows"`
	}
	if code := getJSON(t, e, "/api/installs?sort=messagesTotal", cookie, &page); code != http.StatusOK {
		t.Fatalf("installs = %d", code)
	}
	if len(page.Rows) != 2 {
		t.Fatalf("rows = %+v", page.Rows)
	}
	// 11 today + 5 on 10-07 + 50 archived; the rollup is not per install.
	if a := page.Rows[0]; a.Hash != hashA || a.MessagesToday != 11 || a.Messages7d != 16 || a.MessagesTotal != 66 || !a.HasModelStats {
		t.Fatalf("a = %+v", a)
	}
	if b := page.Rows[1]; b.Hash != hashB || b.MessagesTotal != 0 || b.HasModelStats {
		t.Fatalf("b = %+v", b)
	}
	for _, old := range []string{"callsToday", "calls7d", "callsTotal"} {
		if rec := e.do(http.MethodGet, "/api/installs?sort="+old, "", cookie); rec.Code != http.StatusBadRequest {
			t.Fatalf("sort=%s = %d, want 400", old, rec.Code)
		}
	}

	type detailDay struct {
		Day      string `json:"day"`
		Messages *int64 `json:"messages"`
		OnDevice *int64 `json:"onDevice"`
	}
	var detail struct {
		Install struct {
			MessagesTotal int64 `json:"messagesTotal"`
			HasModelStats bool  `json:"hasModelStats"`
		} `json:"install"`
		Daily []detailDay `json:"daily"`
	}
	if code := getJSON(t, e, "/api/installs/"+hashA, cookie, &detail); code != http.StatusOK {
		t.Fatalf("detail = %d", code)
	}
	if detail.Install.MessagesTotal != 66 || !detail.Install.HasModelStats || len(detail.Daily) != 3 {
		t.Fatalf("detail = %+v", detail)
	}
	d0, d1, d2 := detail.Daily[0], detail.Daily[1], detail.Daily[2] // 10-07, 10-08, 10-09
	if d0.Messages == nil || *d0.Messages != 5 || *d0.OnDevice != 4 {
		t.Fatalf("10-07 = %+v", d0)
	}
	if d1.Messages == nil || *d1.Messages != 0 {
		t.Fatalf("10-08 = %+v, want 0", d1)
	}
	if d2.Messages == nil || *d2.Messages != 11 || *d2.OnDevice != 8 {
		t.Fatalf("10-09 = %+v", d2)
	}

	var other struct {
		Daily []detailDay `json:"daily"`
	}
	if code := getJSON(t, e, "/api/installs/"+hashB, cookie, &other); code != http.StatusOK {
		t.Fatalf("detail b = %d", code)
	}
	for _, d := range other.Daily {
		if d.Messages != nil {
			t.Fatalf("install without model stats: %+v, want null messages", d)
		}
	}
}

func TestEngagementMessagesDistribution(t *testing.T) {
	e := newTestEnv(t)
	seedStats(t, e.store)
	seedModelStats(t, e)
	cookie := e.login(t)

	var eng struct {
		MessagesDistribution []struct {
			Label string `json:"label"`
			Count int    `json:"count"`
		} `json:"messagesDistribution"`
	}
	if code := getJSON(t, e, "/api/engagement?range=7d", cookie, &eng); code != http.StatusOK {
		t.Fatalf("engagement = %d", code)
	}
	// hashA: 11 messages on 10-09, 5 on 10-07. The rollup has no install-days to bucket.
	want := map[string]int{"1": 0, "2-3": 0, "4-6": 1, "7-10": 0, "11-20": 1, "21-50": 0, "51+": 0}
	if len(eng.MessagesDistribution) != len(want) {
		t.Fatalf("messagesDistribution = %+v", eng.MessagesDistribution)
	}
	for _, b := range eng.MessagesDistribution {
		if n, ok := want[b.Label]; !ok || n != b.Count {
			t.Fatalf("messagesDistribution = %+v", eng.MessagesDistribution)
		}
	}
}

func TestOverviewMessages(t *testing.T) {
	e := newTestEnv(t)
	seedStats(t, e.store)
	seedModelStats(t, e)
	cookie := e.login(t)

	var ov struct {
		KPIs struct {
			MessagesPerActiveInstallDay *float64 `json:"messagesPerActiveInstallDay"`
		} `json:"kpis"`
		Daily []struct {
			Day      string `json:"day"`
			Calls    int64  `json:"calls"`
			Messages int64  `json:"messages"`
		} `json:"daily"`
	}
	if code := getJSON(t, e, "/api/overview?range=7d", cookie, &ov); code != http.StatusOK {
		t.Fatalf("overview = %d", code)
	}
	if len(ov.Daily) != 7 || ov.Daily[0].Messages != 10 || ov.Daily[4].Messages != 5 || ov.Daily[4].Calls != 2 ||
		ov.Daily[6].Messages != 11 || ov.Daily[6].Calls != 5 {
		t.Fatalf("daily = %+v", ov.Daily)
	}
	// (10 rollup + 5 + 11) ÷ (2 rollup install-days + 2).
	if got := ov.KPIs.MessagesPerActiveInstallDay; got == nil || *got != 6.5 {
		t.Fatalf("messagesPerActiveInstallDay = %v, want 6.5", got)
	}
}
