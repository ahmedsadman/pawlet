package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestRecordHeartbeatCreatesUnattestedInstall(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	now := time.Date(2026, 10, 13, 8, 0, 0, 0, time.UTC)

	err := s.RecordHeartbeat(ctx, "hash-b", now, []HeartbeatDay{
		{Day: "2026-10-12", AppVersionCode: 27, Alive: true},
		{Day: "2026-10-13", AppVersionCode: 28, Opened: true},
	})
	if err != nil {
		t.Fatalf("RecordHeartbeat() error = %v", err)
	}

	rec, err := s.Install(ctx, "hash-b")
	if err != nil {
		t.Fatalf("Install() error = %v", err)
	}
	if rec.Attested {
		t.Error("Attested = true, want false for a heartbeat-only install")
	}
	if !rec.FirstSeen.Equal(now) || !rec.LastSeen.Equal(now) {
		t.Errorf("seen = %v..%v, want %v", rec.FirstSeen, rec.LastSeen, now)
	}
	if rec.Meta.AppVersionCode != 28 {
		t.Errorf("version = %d, want 28 (latest day)", rec.Meta.AppVersionCode)
	}
	days, err := s.InstallDays(ctx, "hash-b")
	if err != nil {
		t.Fatalf("InstallDays() error = %v", err)
	}
	want := []DayRow{
		{IDHash: "hash-b", Day: "2026-10-12", AppVersionCode: 27, Alive: true},
		// Opened implies alive.
		{IDHash: "hash-b", Day: "2026-10-13", AppVersionCode: 28, Opened: true, Alive: true},
	}
	if len(days) != 2 || days[0] != want[0] || days[1] != want[1] {
		t.Fatalf("days = %+v, want %+v", days, want)
	}
}

func TestRecordHeartbeatFlagsAreSticky(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	now := time.Date(2026, 10, 13, 8, 0, 0, 0, time.UTC)
	for _, d := range []HeartbeatDay{
		{Day: "2026-10-13", AppVersionCode: 27, Opened: true},
		{Day: "2026-10-13", AppVersionCode: 28, Alive: true},
	} {
		if err := s.RecordHeartbeat(ctx, "hash-y", now, []HeartbeatDay{d}); err != nil {
			t.Fatalf("RecordHeartbeat() error = %v", err)
		}
	}
	days, err := s.InstallDays(ctx, "hash-y")
	if err != nil {
		t.Fatalf("InstallDays() error = %v", err)
	}
	want := DayRow{IDHash: "hash-y", Day: "2026-10-13", AppVersionCode: 28, Opened: true, Alive: true}
	if len(days) != 1 || days[0] != want {
		t.Fatalf("days = %+v, want [%+v]", days, want)
	}
}

func TestRecordHeartbeatKeepsSessionAndAttested(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	morning := time.Date(2026, 10, 13, 8, 0, 0, 0, time.UTC)
	if err := s.TouchInstall(ctx, "hash-a", morning, InstallMeta{AppVersionCode: 25, DeviceTier: "DEVICE"}); err != nil {
		t.Fatalf("TouchInstall() error = %v", err)
	}
	evening := morning.Add(10 * time.Hour)
	if err := s.RecordHeartbeat(ctx, "hash-a", evening,
		[]HeartbeatDay{{Day: "2026-10-13", AppVersionCode: 28, Opened: true}}); err != nil {
		t.Fatalf("RecordHeartbeat() error = %v", err)
	}

	rec, err := s.Install(ctx, "hash-a")
	if err != nil {
		t.Fatalf("Install() error = %v", err)
	}
	if !rec.Attested || rec.Meta.DeviceTier != "DEVICE" {
		t.Errorf("attested/tier = %v/%q, want true/DEVICE", rec.Attested, rec.Meta.DeviceTier)
	}
	if !rec.FirstSeen.Equal(morning) || !rec.LastSeen.Equal(evening) {
		t.Errorf("seen = %v..%v, want %v..%v", rec.FirstSeen, rec.LastSeen, morning, evening)
	}
	if rec.Meta.AppVersionCode != 28 {
		t.Errorf("version = %d, want 28", rec.Meta.AppVersionCode)
	}
	days, err := s.InstallDays(ctx, "hash-a")
	if err != nil {
		t.Fatalf("InstallDays() error = %v", err)
	}
	want := DayRow{IDHash: "hash-a", Day: "2026-10-13", AppVersionCode: 28, Opened: true, Alive: true, Session: true}
	if len(days) != 1 || days[0] != want {
		t.Fatalf("days = %+v, want [%+v]", days, want)
	}
}

func TestRecordHeartbeatBacklogDoesNotRollVersionBack(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	now := time.Date(2026, 10, 13, 8, 0, 0, 0, time.UTC)
	if err := s.RecordHeartbeat(ctx, "hash-o", now,
		[]HeartbeatDay{{Day: "2026-10-13", AppVersionCode: 28, Opened: true}}); err != nil {
		t.Fatalf("RecordHeartbeat() error = %v", err)
	}
	// A late batch carrying only an older day.
	if err := s.RecordHeartbeat(ctx, "hash-o", now.Add(time.Hour),
		[]HeartbeatDay{{Day: "2026-10-10", AppVersionCode: 25, Alive: true}}); err != nil {
		t.Fatalf("RecordHeartbeat() error = %v", err)
	}
	rec, err := s.Install(ctx, "hash-o")
	if err != nil {
		t.Fatalf("Install() error = %v", err)
	}
	if rec.Meta.AppVersionCode != 28 {
		t.Errorf("version = %d, want 28 (newest day wins)", rec.Meta.AppVersionCode)
	}
}

func TestRecordHeartbeatEmptyIsNoOp(t *testing.T) {
	s := newTestStore(t)
	if err := s.RecordHeartbeat(context.Background(), "hash-e", time.Now(), nil); err != nil {
		t.Fatalf("RecordHeartbeat(nil) error = %v", err)
	}
	if _, err := s.Install(context.Background(), "hash-e"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Install() err = %v, want ErrNotFound", err)
	}
}
