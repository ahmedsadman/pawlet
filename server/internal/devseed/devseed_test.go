package devseed

import (
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/ahmedsadman/pawlet/server/internal/store"
)

func TestSeedFillsEmptyDatabaseOnce(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dev.db")
	now := time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC)

	sum, err := Seed(path, now, 42)
	if err != nil {
		t.Fatalf("Seed() error = %v", err)
	}
	if sum.Installs < 50 || sum.InstallDays == 0 || sum.Usage == 0 || sum.Counters == 0 {
		t.Fatalf("summary = %+v", sum)
	}
	if sum.From != "2026-07-12" || sum.To != "2026-10-09" {
		t.Fatalf("span = %s..%s", sum.From, sum.To)
	}

	if _, err := Seed(path, now, 42); !errors.Is(err, ErrNotEmpty) {
		t.Fatalf("second Seed() err = %v, want ErrNotEmpty", err)
	}

	st, err := store.OpenExisting(path)
	if err != nil {
		t.Fatalf("OpenExisting() error = %v", err)
	}
	defer func() { _ = st.Close() }()
	info, err := st.ServerInfo(t.Context())
	if err != nil || info[store.InfoImageTag] != "dev-seed" {
		t.Fatalf("server info = %v, %v", info, err)
	}
}
