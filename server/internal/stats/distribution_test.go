package stats

import (
	"testing"

	"github.com/ahmedsadman/pawlet/server/internal/store"
)

func TestMessagesDistribution(t *testing.T) {
	model := []store.ModelRow{
		{IDHash: "a", Day: "2026-10-01", AppVersionCode: 20, Accepted: 1},                               // 1
		{IDHash: "a", Day: "2026-10-02", AppVersionCode: 20, Accepted: 1, Declined: 1},                  // 3 once both
		{IDHash: "a", Day: "2026-10-02", AppVersionCode: 21, Accepted: 1},                               // versions are summed
		{IDHash: "b", Day: "2026-10-02", AppVersionCode: 21, Accepted: 4, Declined: 2},                  // 6
		{IDHash: "b", Day: "2026-10-03", AppVersionCode: 21},                                            // 0: not an active day
		{IDHash: "c", Day: "2026-10-03", AppVersionCode: 21, Accepted: 60},                              // 60
		{IDHash: "c", Day: "2026-10-04", AppVersionCode: 21, Accepted: 15, Declined: 4, Unavailable: 1}, // 20
		{IDHash: "d", Day: "2026-09-01", AppVersionCode: 20, Accepted: 5},                               // outside the range
	}
	got := MessagesDistribution(model, "2026-10-01", "2026-10-04")
	want := []Bucket{
		{"1", 1}, {"2-3", 1}, {"4-6", 1}, {"7-10", 0}, {"11-20", 1}, {"21-50", 0}, {"51+", 1},
	}
	if len(got) != len(want) {
		t.Fatalf("MessagesDistribution() = %+v, want %+v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("MessagesDistribution() = %+v, want %+v", got, want)
		}
	}
	if empty := MessagesDistribution(nil, "2026-10-01", "2026-10-04"); len(empty) != 7 || empty[0].Count != 0 {
		t.Fatalf("empty = %+v, want 7 zero buckets", empty)
	}
}
