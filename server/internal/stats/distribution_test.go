package stats

import (
	"testing"

	"github.com/ahmedsadman/pawlet/server/internal/store"
)

func TestCallsDistribution(t *testing.T) {
	usage := []store.UsageRow{
		{IDHash: "a", Day: "2026-10-01", Calls: 1},
		{IDHash: "a", Day: "2026-10-02", Calls: 5},
		{IDHash: "b", Day: "2026-10-02", Calls: 6},
		{IDHash: "b", Day: "2026-10-03", Calls: 150},
		{IDHash: "c", Day: "2026-10-03", Calls: 200},
		{IDHash: "c", Day: "2026-10-04", Calls: 0},  // not an active day
		{IDHash: "d", Day: "2026-09-01", Calls: 3},  // outside range
	}
	got := CallsDistribution(usage, "2026-10-01", "2026-10-04", 200)
	want := []Bucket{
		{"1", 1}, {"2-5", 1}, {"6-10", 1}, {"11-25", 0}, {"26-50", 0},
		{"51-100", 0}, {"101-199", 1}, {"200+", 1},
	}
	if len(got) != len(want) {
		t.Fatalf("CallsDistribution() = %+v, want %+v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("CallsDistribution() = %+v, want %+v", got, want)
		}
	}
}

func TestCallsDistributionSmallLimit(t *testing.T) {
	got := CallsDistribution(nil, "2026-10-01", "2026-10-01", 20)
	labels := []string{}
	for _, b := range got {
		labels = append(labels, b.Label)
	}
	want := []string{"1", "2-5", "6-10", "11-19", "20+"}
	if len(labels) != len(want) {
		t.Fatalf("labels = %v, want %v", labels, want)
	}
	for i := range want {
		if labels[i] != want[i] {
			t.Fatalf("labels = %v, want %v", labels, want)
		}
	}
}
