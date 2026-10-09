package stats

import (
	"math"

	"github.com/ahmedsadman/pawlet/server/internal/store"
)

// Bucket is one bar of a histogram.
type Bucket struct {
	Label string `json:"label"`
	Count int    `json:"count"`
}

// messageBuckets are the messages-per-day histogram's bars, each with its
// inclusive upper bound.
var messageBuckets = []struct {
	label string
	upper int64
}{
	{"1", 1}, {"2-3", 3}, {"4-6", 6}, {"7-10", 10}, {"11-20", 20}, {"21-50", 50}, {"51+", math.MaxInt64},
}

// installDay keys one install on one UTC day.
type installDay struct{ hash, day string }

// installDayMessages sums each install-day's messages over from..to across
// app versions.
func installDayMessages(rows []store.ModelRow, from, to string) map[installDay]int64 {
	out := map[installDay]int64{}
	for _, m := range rows {
		if m.Day < from || m.Day > to {
			continue
		}
		out[installDay{m.IDHash, m.Day}] += modelCounts(m.Accepted, m.Declined, m.Unavailable).Messages()
	}
	return out
}

// MessagesDistribution buckets every install-day in from..to with at least
// one message by its message count. Callers cap from at the per-install
// retention (store.ModelStatsRetentionDays): the rollup has no install
// identity to bucket.
func MessagesDistribution(rows []store.ModelRow, from, to string) []Bucket {
	out := make([]Bucket, len(messageBuckets))
	for i, b := range messageBuckets {
		out[i] = Bucket{Label: b.label}
	}
	for _, n := range installDayMessages(rows, from, to) {
		if n <= 0 {
			continue
		}
		for i, b := range messageBuckets {
			if n <= b.upper {
				out[i].Count++
				break
			}
		}
	}
	return out
}
