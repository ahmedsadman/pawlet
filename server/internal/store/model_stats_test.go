package store

import (
	"context"
	"reflect"
	"testing"
)

func TestReplaceModelStatsOverwritesOnResend(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()

	first := []ModelStatsDay{{Day: "2026-10-09", AppVersionCode: 21, Accepted: 4, Declined: 1, Unavailable: 0}}
	if err := s.ReplaceModelStats(ctx, "a", first); err != nil {
		t.Fatalf("ReplaceModelStats() error = %v", err)
	}
	resend := []ModelStatsDay{{Day: "2026-10-09", AppVersionCode: 21, Accepted: 7, Declined: 2, Unavailable: 1}}
	if err := s.ReplaceModelStats(ctx, "a", resend); err != nil {
		t.Fatalf("second ReplaceModelStats() error = %v", err)
	}
	// Resending the same totals again must not double them.
	if err := s.ReplaceModelStats(ctx, "a", resend); err != nil {
		t.Fatalf("third ReplaceModelStats() error = %v", err)
	}

	got, err := s.ModelStatsForInstall(ctx, "a")
	if err != nil {
		t.Fatalf("ModelStatsForInstall() error = %v", err)
	}
	if !reflect.DeepEqual(got, resend) {
		t.Fatalf("rows = %+v, want %+v", got, resend)
	}
}

func TestReplaceModelStatsKeysByInstallDayAndVersion(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()

	if err := s.ReplaceModelStats(ctx, "a", []ModelStatsDay{
		{Day: "2026-10-09", AppVersionCode: 22, Accepted: 2},
		{Day: "2026-10-08", AppVersionCode: 21, Accepted: 5},
		{Day: "2026-10-09", AppVersionCode: 21, Declined: 3},
	}); err != nil {
		t.Fatalf("ReplaceModelStats(a) error = %v", err)
	}
	if err := s.ReplaceModelStats(ctx, "b", []ModelStatsDay{
		{Day: "2026-10-09", AppVersionCode: 21, Unavailable: 9},
	}); err != nil {
		t.Fatalf("ReplaceModelStats(b) error = %v", err)
	}

	got, err := s.ModelStatsForInstall(ctx, "a")
	if err != nil {
		t.Fatalf("ModelStatsForInstall() error = %v", err)
	}
	want := []ModelStatsDay{
		{Day: "2026-10-08", AppVersionCode: 21, Accepted: 5},
		{Day: "2026-10-09", AppVersionCode: 21, Declined: 3},
		{Day: "2026-10-09", AppVersionCode: 22, Accepted: 2},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("rows for a = %+v, want %+v", got, want)
	}
}

func TestReplaceModelStatsEmptyIsNoOp(t *testing.T) {
	s := newTestStore(t)

	if err := s.ReplaceModelStats(context.Background(), "a", nil); err != nil {
		t.Fatalf("ReplaceModelStats(nil) error = %v", err)
	}
}

func TestModelStatsForUnknownInstallIsEmpty(t *testing.T) {
	s := newTestStore(t)

	got, err := s.ModelStatsForInstall(context.Background(), "absent")
	if err != nil || len(got) != 0 {
		t.Fatalf("ModelStatsForInstall() = %+v, %v; want empty, nil", got, err)
	}
}
