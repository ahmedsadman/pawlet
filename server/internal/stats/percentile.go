package stats

import "strconv"

// Percentile estimates the q quantile (0 < q <= 1), in milliseconds, from
// classify_latency_ms bucket counts keyed by upper bound. It walks the
// buckets in order until the running total crosses q of all calls, then
// interpolates linearly inside that bucket; the first bucket starts at 0.
// The open-ended "inf" bucket reports its lower edge. ok is false when there
// are no calls.
func Percentile(buckets map[string]int64, boundsMs []int64, q float64) (float64, bool) {
	var total int64
	for _, b := range boundsMs {
		total += buckets[strconv.FormatInt(b, 10)]
	}
	total += buckets["inf"]
	if total == 0 {
		return 0, false
	}
	target := q * float64(total)
	var cum int64
	lower := 0.0
	for _, b := range boundsMs {
		n := buckets[strconv.FormatInt(b, 10)]
		if n > 0 && float64(cum+n) >= target {
			frac := (target - float64(cum)) / float64(n)
			return lower + frac*(float64(b)-lower), true
		}
		cum += n
		lower = float64(b)
	}
	return lower, true
}
