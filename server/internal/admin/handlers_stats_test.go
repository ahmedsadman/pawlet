package admin

import (
	"context"
	"encoding/json"
	"net/http"
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
		CallsDistribution []struct{ Label string } `json:"callsDistribution"`
		Dormant           int                      `json:"dormant"`
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
