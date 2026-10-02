package store

import (
	"context"
	"path/filepath"
	"testing"
	"time"
)

func newTestStore(t *testing.T) *Store {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("Open() error = %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func TestTouchInstallCreatesThenUpdates(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	first := time.Unix(1_700_000_000, 0)

	if err := s.TouchInstall(ctx, "hash-a", first); err != nil {
		t.Fatalf("TouchInstall() error = %v", err)
	}
	later := first.Add(time.Hour)
	if err := s.TouchInstall(ctx, "hash-a", later); err != nil {
		t.Fatalf("second TouchInstall() error = %v", err)
	}

	rec, err := s.Install(ctx, "hash-a")
	if err != nil {
		t.Fatalf("Install() error = %v", err)
	}
	if !rec.FirstSeen.Equal(first) {
		t.Errorf("FirstSeen = %v, want %v", rec.FirstSeen, first)
	}
	if !rec.LastSeen.Equal(later) {
		t.Errorf("LastSeen = %v, want %v", rec.LastSeen, later)
	}
	if rec.Banned {
		t.Error("Banned = true, want false")
	}
}

func TestInstallMissingReturnsNotFound(t *testing.T) {
	s := newTestStore(t)

	_, err := s.Install(context.Background(), "absent")
	if err != ErrNotFound {
		t.Fatalf("err = %v, want ErrNotFound", err)
	}
}

func TestBanIsVisibleToInstall(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	if err := s.TouchInstall(ctx, "hash-b", time.Unix(1_700_000_000, 0)); err != nil {
		t.Fatalf("TouchInstall() error = %v", err)
	}

	if err := s.Ban(ctx, "hash-b", "abuse"); err != nil {
		t.Fatalf("Ban() error = %v", err)
	}

	rec, err := s.Install(ctx, "hash-b")
	if err != nil {
		t.Fatalf("Install() error = %v", err)
	}
	if !rec.Banned || rec.BanReason != "abuse" {
		t.Errorf("rec = %+v, want banned with reason abuse", rec)
	}
}

func TestConcurrentWritesSerialiseWithoutError(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	now := time.Unix(1_700_000_000, 0)

	errs := make(chan error, 10)
	for i := 0; i < 10; i++ {
		go func() { errs <- s.TouchInstall(ctx, "hash-c", now) }()
	}
	for i := 0; i < 10; i++ {
		if err := <-errs; err != nil {
			t.Fatalf("concurrent TouchInstall() error = %v", err)
		}
	}
}
