package stats

import (
	"testing"

	"github.com/ahmedsadman/pawlet/server/internal/store"
)

func TestSuccessRate(t *testing.T) {
	r := SuccessRate(map[string]int64{
		"ok": 90, "upstream_retryable": 5, "upstream_429": 5,
		"unauthorized": 50, "client_cancelled": 7, "rate_limited_daily": 9,
	})
	if r == nil || *r != 0.9 {
		t.Fatalf("SuccessRate() = %v, want 0.9 (client errors excluded)", r)
	}
	if SuccessRate(map[string]int64{"unauthorized": 3}) != nil {
		t.Fatal("no LLM-path calls should be nil")
	}
}

func TestBuildReliability(t *testing.T) {
	days := []string{"2026-10-01", "2026-10-02"}
	counters := []store.CounterRow{
		{Day: "2026-10-01", Metric: "classify_outcome", Key: "ok", Count: 4},
		{Day: "2026-10-01", Metric: "classify_outcome", Key: "upstream_429", Count: 1},
		{Day: "2026-10-01", Metric: "session_outcome", Key: "cert_mismatch", Count: 2},
		{Day: "2026-10-01", Metric: "classify_latency_ms", Key: "1000", Count: 4},
		{Day: "2026-10-01", Metric: "model", Key: "m1", Count: 3},
		{Day: "2026-10-02", Metric: "model", Key: "m1", Count: 1},
		{Day: "2026-10-02", Metric: "model", Key: "m2", Count: 5},
		{Day: "2026-10-01", Metric: "category", Key: "bill", Count: 4},
	}
	usage := []store.UsageRow{{IDHash: "a", Day: "2026-10-01", Calls: 5, Tokens: 400}}

	r := BuildReliability(days, counters, usage, bounds)
	if len(r.ClassifyOutcomes) != 2 || r.ClassifyOutcomes[0].Counts["ok"] != 4 || len(r.ClassifyOutcomes[1].Counts) != 0 {
		t.Fatalf("classify outcomes = %+v", r.ClassifyOutcomes)
	}
	if r.SessionOutcomes[0].Counts["cert_mismatch"] != 2 {
		t.Fatalf("session outcomes = %+v", r.SessionOutcomes)
	}
	if r.SuccessRate[0].Value == nil || *r.SuccessRate[0].Value != 0.8 || r.SuccessRate[1].Value != nil {
		t.Fatalf("success rate = %+v", r.SuccessRate)
	}
	l := r.Latency[0]
	if l.Count != 4 || l.P50 == nil || *l.P50 != 750 || r.Latency[1].P50 != nil {
		t.Fatalf("latency = %+v", r.Latency)
	}
	if len(r.Models) != 2 || r.Models[0] != (KeyCount{"m2", 5}) || r.Models[1] != (KeyCount{"m1", 4}) {
		t.Fatalf("models = %+v", r.Models)
	}
	if r.Categories[0].Counts["bill"] != 4 {
		t.Fatalf("categories = %+v", r.Categories)
	}
	if r.TokensPerCall[0].Value == nil || *r.TokensPerCall[0].Value != 100 || r.TokensPerCall[1].Value != nil {
		t.Fatalf("tokens per call = %+v", r.TokensPerCall)
	}
}
