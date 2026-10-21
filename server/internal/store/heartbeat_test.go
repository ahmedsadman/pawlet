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

func TestRecordHeartbeatThenSessionSameDay(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	now := time.Date(2026, 10, 13, 8, 0, 0, 0, time.UTC)

	if err := s.RecordHeartbeat(ctx, "hash-m", now,
		[]HeartbeatDay{{Day: "2026-10-13", AppVersionCode: 28, Opened: true}}); err != nil {
		t.Fatalf("RecordHeartbeat() error = %v", err)
	}
	if err := s.TouchInstall(ctx, "hash-m", now.Add(time.Hour),
		InstallMeta{AppVersionCode: 28}); err != nil {
		t.Fatalf("TouchInstall() error = %v", err)
	}

	rec, err := s.Install(ctx, "hash-m")
	if err != nil {
		t.Fatalf("Install() error = %v", err)
	}
	if !rec.Attested {
		t.Error("Attested = false, want true after TouchInstall")
	}
	days, err := s.InstallDays(ctx, "hash-m")
	if err != nil {
		t.Fatalf("InstallDays() error = %v", err)
	}
	want := DayRow{IDHash: "hash-m", Day: "2026-10-13", AppVersionCode: 28, Opened: true, Alive: true, Session: true}
	if len(days) != 1 || days[0] != want {
		t.Fatalf("days = %+v, want [%+v]", days, want)
	}
}

func TestRecordHeartbeatNullVersionPath(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	now := time.Date(2026, 10, 13, 8, 0, 0, 0, time.UTC)

	if err := s.RecordHeartbeat(ctx, "hash-n", now,
		[]HeartbeatDay{{Day: "2026-10-12", AppVersionCode: 27, Alive: true}}); err != nil {
		t.Fatalf("RecordHeartbeat() error = %v", err)
	}
	// TouchInstall with NULL version (InstallMeta{} means all fields are 0/empty).
	if err := s.TouchInstall(ctx, "hash-n", now.Add(time.Hour), InstallMeta{}); err != nil {
		t.Fatalf("TouchInstall() error = %v", err)
	}
	// Late batch with only an older day.
	if err := s.RecordHeartbeat(ctx, "hash-n", now.Add(2*time.Hour),
		[]HeartbeatDay{{Day: "2026-10-11", AppVersionCode: 26, Alive: true}}); err != nil {
		t.Fatalf("RecordHeartbeat() error = %v", err)
	}

	rec, err := s.Install(ctx, "hash-n")
	if err != nil {
		t.Fatalf("Install() error = %v", err)
	}
	if rec.Meta.AppVersionCode != 27 {
		t.Errorf("version = %d, want 27 (newest day WITH a version)", rec.Meta.AppVersionCode)
	}
}

func TestRecordHeartbeatSameDayVersionMonotonic(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	now := time.Date(2026, 10, 13, 8, 0, 0, 0, time.UTC)

	if err := s.RecordHeartbeat(ctx, "hash-p", now,
		[]HeartbeatDay{{Day: "2026-10-13", AppVersionCode: 28, Opened: true}}); err != nil {
		t.Fatalf("RecordHeartbeat() error = %v", err)
	}
	// Late batch with older build for the same day.
	if err := s.RecordHeartbeat(ctx, "hash-p", now.Add(time.Hour),
		[]HeartbeatDay{{Day: "2026-10-13", AppVersionCode: 27, Alive: true}}); err != nil {
		t.Fatalf("RecordHeartbeat() error = %v", err)
	}

	rec, err := s.Install(ctx, "hash-p")
	if err != nil {
		t.Fatalf("Install() error = %v", err)
	}
	if rec.Meta.AppVersionCode != 28 {
		t.Errorf("install version = %d, want 28", rec.Meta.AppVersionCode)
	}
	days, err := s.InstallDays(ctx, "hash-p")
	if err != nil {
		t.Fatalf("InstallDays() error = %v", err)
	}
	if len(days) != 1 {
		t.Fatalf("len(days) = %d, want 1", len(days))
	}
	if days[0].AppVersionCode != 28 {
		t.Errorf("day version = %d, want 28 (monotonic)", days[0].AppVersionCode)
	}
}

func TestRecordHeartbeatZeroVersionDoesNotWipe(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	now := time.Date(2026, 10, 13, 8, 0, 0, 0, time.UTC)

	if err := s.RecordHeartbeat(ctx, "hash-z", now,
		[]HeartbeatDay{{Day: "2026-10-13", AppVersionCode: 28, Opened: true}}); err != nil {
		t.Fatalf("RecordHeartbeat() error = %v", err)
	}
	// A heartbeat without a version (0 becomes NULL via nullInt).
	if err := s.RecordHeartbeat(ctx, "hash-z", now.Add(time.Hour),
		[]HeartbeatDay{{Day: "2026-10-13", AppVersionCode: 0, Alive: true}}); err != nil {
		t.Fatalf("RecordHeartbeat() error = %v", err)
	}

	days, err := s.InstallDays(ctx, "hash-z")
	if err != nil {
		t.Fatalf("InstallDays() error = %v", err)
	}
	if len(days) != 1 {
		t.Fatalf("len(days) = %d, want 1", len(days))
	}
	if days[0].AppVersionCode != 28 {
		t.Errorf("day version = %d, want 28 (zero should not wipe)", days[0].AppVersionCode)
	}
}

func TestRecordHeartbeatLaterHeartbeatOverwritesLLM(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	now := time.Date(2026, 10, 13, 8, 0, 0, 0, time.UTC)

	if err := s.RecordHeartbeat(ctx, "hash-l1", now,
		[]HeartbeatDay{{Day: "2026-10-13", AppVersionCode: 28, Opened: true, LLM: "on"}}); err != nil {
		t.Fatalf("RecordHeartbeat() error = %v", err)
	}
	if err := s.RecordHeartbeat(ctx, "hash-l1", now.Add(time.Hour),
		[]HeartbeatDay{{Day: "2026-10-13", AppVersionCode: 28, Alive: true, LLM: "off"}}); err != nil {
		t.Fatalf("RecordHeartbeat() error = %v", err)
	}

	days, err := s.InstallDaysBetween(ctx, "2026-10-13", "2026-10-13")
	if err != nil {
		t.Fatalf("InstallDaysBetween() error = %v", err)
	}
	if len(days) != 1 {
		t.Fatalf("len(days) = %d, want 1", len(days))
	}
	if days[0].LLM != "off" {
		t.Errorf("LLM = %q, want off (later heartbeat wins)", days[0].LLM)
	}
}

func TestRecordHeartbeatMissingLLMKeepsStoredValue(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	now := time.Date(2026, 10, 13, 8, 0, 0, 0, time.UTC)

	if err := s.RecordHeartbeat(ctx, "hash-l2", now,
		[]HeartbeatDay{{Day: "2026-10-13", AppVersionCode: 28, Opened: true, LLM: "on"}}); err != nil {
		t.Fatalf("RecordHeartbeat() error = %v", err)
	}
	if err := s.RecordHeartbeat(ctx, "hash-l2", now.Add(time.Hour),
		[]HeartbeatDay{{Day: "2026-10-13", AppVersionCode: 28, Alive: true, LLM: ""}}); err != nil {
		t.Fatalf("RecordHeartbeat() error = %v", err)
	}

	days, err := s.InstallDays(ctx, "hash-l2")
	if err != nil {
		t.Fatalf("InstallDays() error = %v", err)
	}
	if len(days) != 1 {
		t.Fatalf("len(days) = %d, want 1", len(days))
	}
	if days[0].LLM != "on" {
		t.Errorf("LLM = %q, want on (empty should not clear)", days[0].LLM)
	}
}
