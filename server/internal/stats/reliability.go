package stats

import (
	"cmp"
	"slices"

	"github.com/ahmedsadman/pawlet/server/internal/metrics"
	"github.com/ahmedsadman/pawlet/server/internal/store"
)

// DayCounts is one day's counts per key.
type DayCounts struct {
	Day    string           `json:"day"`
	Counts map[string]int64 `json:"counts"`
}

// DayValue is one day's value; nil when it is undefined that day.
type DayValue struct {
	Day   string   `json:"day"`
	Value *float64 `json:"value"`
}

// LatencyDay is one day's estimated classify latency.
type LatencyDay struct {
	Day   string   `json:"day"`
	P50   *float64 `json:"p50"`
	P95   *float64 `json:"p95"`
	Count int64    `json:"count"`
}

// KeyCount is a total for one key.
type KeyCount struct {
	Key   string `json:"key"`
	Count int64  `json:"count"`
}

// Reliability is everything the reliability page plots.
type Reliability struct {
	ClassifyOutcomes []DayCounts  `json:"classifyOutcomes"`
	SessionOutcomes  []DayCounts  `json:"sessionOutcomes"`
	SuccessRate      []DayValue   `json:"successRate"`
	Latency          []LatencyDay `json:"latency"`
	Models           []KeyCount   `json:"models"`
	Categories       []DayCounts  `json:"categories"`
	TokensPerCall    []DayValue   `json:"tokensPerCall"`
}

// llmPathKeys are the classify outcomes of calls that reached the LLM step.
var llmPathKeys = []string{
	metrics.OK, metrics.Upstream429, metrics.UpstreamRetryable, metrics.UpstreamRejected, metrics.Internal,
}

// SuccessRate is ok over every classify call that reached the LLM step; nil
// when there were none. Client errors, quota denials and cancellations are
// not the service's failures, so they are left out.
func SuccessRate(classify map[string]int64) *float64 {
	var denom int64
	for _, k := range llmPathKeys {
		denom += classify[k]
	}
	if denom == 0 {
		return nil
	}
	v := float64(classify[metrics.OK]) / float64(denom)
	return &v
}

// counterIndex is metric → day → key → count.
type counterIndex map[string]map[string]map[string]int64

func indexCounters(rows []store.CounterRow) counterIndex {
	idx := counterIndex{}
	for _, c := range rows {
		byDay := idx[c.Metric]
		if byDay == nil {
			byDay = map[string]map[string]int64{}
			idx[c.Metric] = byDay
		}
		keys := byDay[c.Day]
		if keys == nil {
			keys = map[string]int64{}
			byDay[c.Day] = keys
		}
		keys[c.Key] += c.Count
	}
	return idx
}

// get never returns nil, so JSON renders {} rather than null.
func (idx counterIndex) get(metric, day string) map[string]int64 {
	if m := idx[metric][day]; m != nil {
		return m
	}
	return map[string]int64{}
}

func sortedKeyCounts(m map[string]int64) []KeyCount {
	out := make([]KeyCount, 0, len(m))
	for k, n := range m {
		out = append(out, KeyCount{Key: k, Count: n})
	}
	slices.SortFunc(out, func(a, b KeyCount) int {
		if c := cmp.Compare(b.Count, a.Count); c != 0 {
			return c
		}
		return cmp.Compare(a.Key, b.Key)
	})
	return out
}

// BuildReliability assembles the reliability page for days from counters and
// usage covering those days.
func BuildReliability(days []string, counters []store.CounterRow, usage []store.UsageRow, boundsMs []int64) Reliability {
	idx := indexCounters(counters)
	tokens := map[string]int64{}
	for _, u := range usage {
		tokens[u.Day] += u.Tokens
	}

	r := Reliability{
		ClassifyOutcomes: make([]DayCounts, 0, len(days)),
		SessionOutcomes:  make([]DayCounts, 0, len(days)),
		SuccessRate:      make([]DayValue, 0, len(days)),
		Latency:          make([]LatencyDay, 0, len(days)),
		Categories:       make([]DayCounts, 0, len(days)),
		TokensPerCall:    make([]DayValue, 0, len(days)),
	}
	models := map[string]int64{}
	for _, d := range days {
		classify := idx.get(metrics.ClassifyOutcome, d)
		r.ClassifyOutcomes = append(r.ClassifyOutcomes, DayCounts{Day: d, Counts: classify})
		r.SessionOutcomes = append(r.SessionOutcomes, DayCounts{Day: d, Counts: idx.get(metrics.SessionOutcome, d)})
		r.SuccessRate = append(r.SuccessRate, DayValue{Day: d, Value: SuccessRate(classify)})
		r.Categories = append(r.Categories, DayCounts{Day: d, Counts: idx.get(metrics.Category, d)})

		lat := idx.get(metrics.ClassifyLatency, d)
		ld := LatencyDay{Day: d}
		for _, n := range lat {
			ld.Count += n
		}
		if p, ok := Percentile(lat, boundsMs, 0.5); ok {
			ld.P50 = &p
		}
		if p, ok := Percentile(lat, boundsMs, 0.95); ok {
			ld.P95 = &p
		}
		r.Latency = append(r.Latency, ld)

		var perCall *float64
		if ok := classify[metrics.OK]; ok > 0 {
			v := float64(tokens[d]) / float64(ok)
			perCall = &v
		}
		r.TokensPerCall = append(r.TokensPerCall, DayValue{Day: d, Value: perCall})

		for k, n := range idx.get(metrics.Model, d) {
			models[k] += n
		}
	}
	r.Models = sortedKeyCounts(models)
	return r
}
