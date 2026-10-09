package stats

import (
	"math"
	"testing"
)

var bounds = []int64{250, 500, 1000, 2000, 4000, 8000, 16000, 32000}

func TestPercentileInterpolatesWithinBucket(t *testing.T) {
	buckets := map[string]int64{
		"500": 120, "1000": 1900, "2000": 2210, "4000": 1800, "8000": 600, "16000": 70, "32000": 12,
	}
	p50, ok := Percentile(buckets, bounds, 0.5)
	// target 3356: cumulative 2020 before the 1000-2000 bucket of 2210.
	want := 1000 + (3356.0-2020.0)/2210.0*1000
	if !ok || math.Abs(p50-want) > 0.01 {
		t.Fatalf("p50 = %v, %v; want %v", p50, ok, want)
	}
	p95, _ := Percentile(buckets, bounds, 0.95)
	if p95 < 4000 || p95 > 8000 {
		t.Fatalf("p95 = %v, want within the 4000-8000 bucket", p95)
	}
}

func TestPercentileFirstBucketStartsAtZero(t *testing.T) {
	p, ok := Percentile(map[string]int64{"250": 4}, bounds, 0.5)
	if !ok || p != 125 {
		t.Fatalf("p = %v, %v; want 125", p, ok)
	}
}

func TestPercentileInfBucketReportsLowerEdge(t *testing.T) {
	p, ok := Percentile(map[string]int64{"inf": 3}, bounds, 0.5)
	if !ok || p != 32000 {
		t.Fatalf("p = %v, %v; want 32000", p, ok)
	}
}

func TestPercentileEmpty(t *testing.T) {
	if _, ok := Percentile(nil, bounds, 0.5); ok {
		t.Fatal("Percentile(empty) ok = true")
	}
}
