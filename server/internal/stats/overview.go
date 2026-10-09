package stats

import (
	"strconv"
	"strings"

	"github.com/ahmedsadman/pawlet/server/internal/store"
)

// ServerInfo is pawletd's published configuration.
type ServerInfo struct {
	DailyPerInstall int      `json:"dailyPerInstall"`
	BurstPerMin     int      `json:"burstPerMin"`
	GlobalDailyCap  int      `json:"globalDailyCap"`
	Models          []string `json:"models"`
	StartedAt       int64    `json:"startedAt"`
	ImageTag        string   `json:"imageTag"`
}

// ParseServerInfo reads the server_info table. Missing or malformed values
// read as zero.
func ParseServerInfo(m map[string]string) ServerInfo {
	atoi := func(k string) int {
		n, _ := strconv.Atoi(m[k])
		return n
	}
	started, _ := strconv.ParseInt(m[store.InfoStartedAt], 10, 64)
	models := []string{}
	for _, part := range strings.Split(m[store.InfoModels], ",") {
		if p := strings.TrimSpace(part); p != "" {
			models = append(models, p)
		}
	}
	return ServerInfo{
		DailyPerInstall: atoi(store.InfoDailyPerInstall),
		BurstPerMin:     atoi(store.InfoBurstPerMin),
		GlobalDailyCap:  atoi(store.InfoGlobalDailyCap),
		Models:          models,
		StartedAt:       started,
		ImageTag:        m[store.InfoImageTag],
	}
}

// OverviewKPIs are the overview page's tiles.
type OverviewKPIs struct {
	AttestedInstalls         int      `json:"attestedInstalls"`
	Banned                   int      `json:"banned"`
	NewInstalls              int      `json:"newInstalls"`
	NewInstallsPrev          int      `json:"newInstallsPrev"`
	DAU                      int      `json:"dau"`
	WAU                      int      `json:"wau"`
	MAU                      int      `json:"mau"`
	CallsToday               int64    `json:"callsToday"`
	TokensToday              int64    `json:"tokensToday"`
	SuccessRateToday         *float64 `json:"successRateToday"`
	CallsPerActiveInstallDay *float64 `json:"callsPerActiveInstallDay"`
}

// OverviewDay is one day of the overview charts.
type OverviewDay struct {
	Day            string `json:"day"`
	Calls          int64  `json:"calls"`
	Tokens         int64  `json:"tokens"`
	ActiveInstalls int    `json:"activeInstalls"`
	NewInstalls    int    `json:"newInstalls"`
}

// Overview is the overview page minus server info.
type Overview struct {
	KPIs  OverviewKPIs  `json:"kpis"`
	Daily []OverviewDay `json:"daily"`
}

// OverviewInput is what BuildOverview needs. Activity must be ModeAny and
// reach 29 days before Range.From.
type OverviewInput struct {
	Range         Range
	Today         string
	Installs      []store.Install
	Usage         []store.UsageRow
	Activity      Activity
	CountersToday map[string]int64
}

// BuildOverview computes the overview tiles and daily series. "New installs
// previous" is the same-length window just before the range.
func BuildOverview(in OverviewInput) Overview {
	days := Days(in.Range.From, in.Range.To)
	prevFrom := AddDays(in.Range.From, -len(days))
	prevTo := AddDays(in.Range.From, -1)

	k := OverviewKPIs{AttestedInstalls: len(in.Installs)}
	newByDay := map[string]int{}
	for _, inst := range in.Installs {
		d := inst.FirstSeen.UTC().Format(DayLayout)
		newByDay[d]++
		if inst.Banned {
			k.Banned++
		}
		if d >= in.Range.From && d <= in.Range.To {
			k.NewInstalls++
		}
		if d >= prevFrom && d <= prevTo {
			k.NewInstallsPrev++
		}
	}

	calls, tokens := map[string]int64{}, map[string]int64{}
	var rangeCalls int64
	activeInstallDays := 0
	for _, u := range in.Usage {
		if u.Day < in.Range.From || u.Day > in.Range.To {
			continue
		}
		calls[u.Day] += u.Calls
		tokens[u.Day] += u.Tokens
		rangeCalls += u.Calls
		if u.Calls > 0 {
			activeInstallDays++
		}
	}
	k.CallsToday = calls[in.Today]
	k.TokensToday = tokens[in.Today]
	if activeInstallDays > 0 {
		v := float64(rangeCalls) / float64(activeInstallDays)
		k.CallsPerActiveInstallDay = &v
	}
	k.SuccessRateToday = SuccessRate(in.CountersToday)

	now := ActiveSeries(in.Activity, []string{in.Today})[0]
	k.DAU, k.WAU, k.MAU = now.DAU, now.WAU, now.MAU

	series := ActiveSeries(in.Activity, days)
	daily := make([]OverviewDay, len(days))
	for i, d := range days {
		daily[i] = OverviewDay{
			Day: d, Calls: calls[d], Tokens: tokens[d],
			ActiveInstalls: series[i].DAU, NewInstalls: newByDay[d],
		}
	}
	return Overview{KPIs: k, Daily: daily}
}
