package stats

import "github.com/ahmedsadman/pawlet/server/internal/store"

// RollingWindowDays is the on-device rate's rolling window, the day itself
// included.
const RollingWindowDays = 7

// MarkerMinMessages is the fewest messages a day needs before its majority
// app version can move a version marker.
const MarkerMinMessages = 20

// ModelCounts tallies local-model verdicts. Every message the sender gate
// lets through gets exactly one verdict, so the three never overlap.
type ModelCounts struct {
	Accepted    int64
	Declined    int64
	Unavailable int64
}

func modelCounts(accepted, declined, unavailable int64) ModelCounts {
	return ModelCounts{Accepted: accepted, Declined: declined, Unavailable: unavailable}
}

// Messages is every message the model saw. LLM calls are not added: a
// message reaches the LLM only after the model declined it.
func (c ModelCounts) Messages() int64 { return c.Accepted + c.Declined + c.Unavailable }

func (c ModelCounts) plus(o ModelCounts) ModelCounts {
	return modelCounts(c.Accepted+o.Accepted, c.Declined+o.Declined, c.Unavailable+o.Unavailable)
}

// OnDeviceRate is accepted ÷ (accepted + declined); nil when both are zero.
// Unavailable is a model error rather than a decision, so it is left out.
func OnDeviceRate(c ModelCounts) *float64 {
	denom := c.Accepted + c.Declined
	if denom == 0 {
		return nil
	}
	v := float64(c.Accepted) / float64(denom)
	return &v
}

// modelIndex is day → app version → counts, over per-install and rollup rows.
type modelIndex map[string]map[int64]ModelCounts

func (idx modelIndex) add(day string, version int64, c ModelCounts) {
	byVersion := idx[day]
	if byVersion == nil {
		byVersion = map[int64]ModelCounts{}
		idx[day] = byVersion
	}
	byVersion[version] = byVersion[version].plus(c)
}

func indexModel(daily []store.ModelRow, rollup []store.ModelRollupRow) modelIndex {
	idx := modelIndex{}
	for _, r := range daily {
		idx.add(r.Day, r.AppVersionCode, modelCounts(r.Accepted, r.Declined, r.Unavailable))
	}
	for _, r := range rollup {
		idx.add(r.Day, r.AppVersionCode, modelCounts(r.Accepted, r.Declined, r.Unavailable))
	}
	return idx
}

// day sums one day across app versions.
func (idx modelIndex) day(d string) ModelCounts {
	var c ModelCounts
	for _, v := range idx[d] {
		c = c.plus(v)
	}
	return c
}

// RateDay is one day's on-device rate; nil when undefined.
type RateDay struct {
	Day  string   `json:"day"`
	Rate *float64 `json:"rate"`
}

// rollingRates weights by volume: Σaccepted ÷ Σ(accepted + declined) over
// each day and the RollingWindowDays-1 days before it. idx must reach that
// far before days[0] so the line does not ramp up at the left edge.
func rollingRates(idx modelIndex, days []string) []RateDay {
	out := make([]RateDay, 0, len(days))
	for _, d := range days {
		var c ModelCounts
		for i := range RollingWindowDays {
			c = c.plus(idx.day(AddDays(d, -i)))
		}
		out = append(out, RateDay{Day: d, Rate: OnDeviceRate(c)})
	}
	return out
}
