package metrics

import (
	"strconv"
	"time"
)

// latencyBoundsMs are the classify_latency_ms bucket upper bounds. They double
// each step because LLM latency spans sub-second to tens of seconds on free
// models. Changing them splits the stored history.
var latencyBoundsMs = []int64{250, 500, 1000, 2000, 4000, 8000, 16000, 32000}

// LatencyBucket returns the classify_latency_ms key for d: the smallest bound,
// in milliseconds, that d fits under, or "inf" past the last one.
func LatencyBucket(d time.Duration) string {
	ms := d.Milliseconds()
	for _, bound := range latencyBoundsMs {
		if ms <= bound {
			return strconv.FormatInt(bound, 10)
		}
	}
	return "inf"
}
