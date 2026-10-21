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
	Installs         int   `json:"installs"`
	AttestedInstalls int   `json:"attestedInstalls"`
	Banned           int   `json:"banned"`
	NewInstalls      int   `json:"newInstalls"`
	NewInstallsPrev  int   `json:"newInstallsPrev"`
	DAU              int   `json:"dau"`
	WAU              int   `json:"wau"`
	MAU              int   `json:"mau"`
	CallsToday       int64 `json:"callsToday"`
	// AttemptsToday counts retries too: it is what the global cap charges.
	AttemptsToday               int64    `json:"attemptsToday"`
	TokensToday                 int64    `json:"tokensToday"`
	SuccessRateToday            *float64 `json:"successRateToday"`
	CallsPerActiveInstallDay    *float64 `json:"callsPerActiveInstallDay"`
	MessagesPerActiveInstallDay *float64 `json:"messagesPerActiveInstallDay"`
}

// OverviewDay is one day of the overview charts.
type OverviewDay struct {
	Day            string `json:"day"`
	Calls          int64  `json:"calls"`
	Messages       int64  `json:"messages"`
	Tokens         int64  `json:"tokens"`
	ActiveInstalls int    `json:"activeInstalls"`
	NewInstalls    int    `json:"newInstalls"`
}

// Overview is the overview page minus server info.
type Overview struct {
	KPIs      OverviewKPIs  `json:"kpis"`
	Daily     []OverviewDay `json:"daily"`
	LLMGroups []KeyCount    `json:"llmGroups"`
}

// OverviewInput is what BuildOverview needs. Activity must be ModeAny and
// reach 29 days before Range.From. CountersToday holds today's classify_outcome
// counts only. Model and ModelRollup cover Range. Days are install_days rows
// loaded with the same window as Usage (29 days before Range.From).
type OverviewInput struct {
	Range         Range
	Today         string
	Installs      []store.Install
	Usage         []store.UsageRow
	Days          []store.DayRow
	Activity      Activity
	CountersToday map[string]int64
	Model         []store.ModelRow
	ModelRollup   []store.ModelRollupRow
}

// BuildOverview computes the overview tiles and daily series. "New installs
// previous" is the same-length window just before the range.
func BuildOverview(in OverviewInput) Overview {
	days := Days(in.Range.From, in.Range.To)
	prevFrom := AddDays(in.Range.From, -len(days))
	prevTo := AddDays(in.Range.From, -1)

	k := OverviewKPIs{Installs: len(in.Installs)}
	newByDay := map[string]int{}
	for _, inst := range in.Installs {
		d := inst.FirstSeen.UTC().Format(DayLayout)
		newByDay[d]++
		if inst.Attested {
			k.AttestedInstalls++
		}
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
		if u.Day == in.Today {
			k.AttemptsToday += u.Attempts
		}
		rangeCalls += u.Calls
		if classified(u) {
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
	messages, perInstallDay := rangeMessages(in)
	k.MessagesPerActiveInstallDay = perInstallDay

	now := ActiveSeries(in.Activity, []string{in.Today})[0]
	k.DAU, k.WAU, k.MAU = now.DAU, now.WAU, now.MAU

	series := ActiveSeries(in.Activity, days)
	daily := make([]OverviewDay, len(days))
	for i, d := range days {
		daily[i] = OverviewDay{
			Day: d, Calls: calls[d], Messages: messages[d], Tokens: tokens[d],
			ActiveInstalls: series[i].DAU, NewInstalls: newByDay[d],
		}
	}

	// LLM groups: count each active install under its latest in-range group.
	activeInstalls := map[string]struct{}{}
	for _, d := range days {
		for h := range in.Activity[d] {
			activeInstalls[h] = struct{}{}
		}
	}
	latestLLM := map[string]string{} // install → latest non-empty LLM
	latestDay := map[string]string{} // install → day of that LLM
	for _, row := range in.Days {
		if row.Day < in.Range.From || row.Day > in.Range.To || row.LLM == "" {
			continue
		}
		if latestDay[row.IDHash] == "" || row.Day > latestDay[row.IDHash] {
			latestLLM[row.IDHash] = row.LLM
			latestDay[row.IDHash] = row.Day
		}
	}
	classifiedInstalls := map[string]struct{}{}
	for _, u := range in.Usage {
		if u.Day >= in.Range.From && u.Day <= in.Range.To && classified(u) {
			classifiedInstalls[u.IDHash] = struct{}{}
		}
	}
	groupCounts := map[string]int64{"on": 0, "off": 0, "byok": 0, "none": 0, "unknown": 0}
	for h := range activeInstalls {
		if grp := latestLLM[h]; grp != "" {
			groupCounts[grp]++
		} else if _, ok := classifiedInstalls[h]; ok {
			groupCounts["on"]++
		} else {
			groupCounts["unknown"]++
		}
	}
	llmGroups := []KeyCount{
		{Key: "on", Count: groupCounts["on"]},
		{Key: "off", Count: groupCounts["off"]},
		{Key: "byok", Count: groupCounts["byok"]},
		{Key: "none", Count: groupCounts["none"]},
		{Key: "unknown", Count: groupCounts["unknown"]},
	}

	return Overview{KPIs: k, Daily: daily, LLMGroups: llmGroups}
}

// rangeMessages sums messages per day over in.Range and averages them over
// install-days with at least one message. A rollup row brings the
// install-days folded into it, since its per-install rows are gone.
func rangeMessages(in OverviewInput) (map[string]int64, *float64) {
	perDay := map[string]int64{}
	var total, installDays int64
	for k, n := range installDayMessages(in.Model, in.Range.From, in.Range.To) {
		perDay[k.day] += n
		total += n
		if n > 0 {
			installDays++
		}
	}
	for _, r := range in.ModelRollup {
		if r.Day < in.Range.From || r.Day > in.Range.To {
			continue
		}
		n := modelCounts(r.Accepted, r.Declined, r.Unavailable).Messages()
		perDay[r.Day] += n
		total += n
		// install_count counts install x version rows, so an install that
		// switched versions on a folded day counts twice. This slightly
		// overcounts install-days, only for ranges reaching past 90 days.
		installDays += r.InstallCount
	}
	if installDays == 0 {
		return perDay, nil
	}
	v := float64(total) / float64(installDays)
	return perDay, &v
}
