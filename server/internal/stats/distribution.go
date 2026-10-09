package stats

import (
	"fmt"

	"github.com/ahmedsadman/pawlet/server/internal/store"
)

// Bucket is one bar of a histogram.
type Bucket struct {
	Label string `json:"label"`
	Count int    `json:"count"`
}

// distributionEdges are the upper bounds of the fixed buckets below the
// daily limit.
var distributionEdges = []int64{1, 5, 10, 25, 50, 100}

// CallsDistribution buckets every install-day with calls in from..to by its
// call count. The last bucket holds days at or over the daily limit.
func CallsDistribution(usage []store.UsageRow, from, to string, limit int64) []Bucket {
	var uppers []int64
	for _, e := range distributionEdges {
		if e < limit-1 {
			uppers = append(uppers, e)
		}
	}
	if limit-1 >= 1 {
		uppers = append(uppers, limit-1)
	}

	buckets := make([]Bucket, 0, len(uppers)+1)
	lower := int64(1)
	for _, u := range uppers {
		label := fmt.Sprintf("%d-%d", lower, u)
		if lower == u {
			label = fmt.Sprintf("%d", u)
		}
		buckets = append(buckets, Bucket{Label: label})
		lower = u + 1
	}
	buckets = append(buckets, Bucket{Label: fmt.Sprintf("%d+", limit)})

	for _, row := range usage {
		if row.Calls <= 0 || row.Day < from || row.Day > to {
			continue
		}
		idx := len(uppers) // at or over the limit
		for i, u := range uppers {
			if row.Calls <= u {
				idx = i
				break
			}
		}
		buckets[idx].Count++
	}
	return buckets
}
