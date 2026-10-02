package store

import (
	"context"
	"errors"
	"fmt"
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
	if !errors.Is(err, ErrNotFound) {
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

	// Distinct hashes so the run proves every write landed, not merely that
	// repeated upserts of one row avoided SQLITE_BUSY.
	const writers = 10
	errs := make(chan error, writers)
	for i := 0; i < writers; i++ {
		go func(i int) {
			errs <- s.TouchInstall(ctx, fmt.Sprintf("hash-c-%d", i), now)
		}(i)
	}
	for i := 0; i < writers; i++ {
		if err := <-errs; err != nil {
			t.Fatalf("concurrent TouchInstall() error = %v", err)
		}
	}

	for i := 0; i < writers; i++ {
		if _, err := s.Install(ctx, fmt.Sprintf("hash-c-%d", i)); err != nil {
			t.Errorf("install %d missing after concurrent writes: %v", i, err)
		}
	}
}
