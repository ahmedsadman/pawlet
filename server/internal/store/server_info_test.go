package store

import (
	"context"
	"testing"
)

func TestPutServerInfoRoundTrips(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()

	in := map[string]string{InfoDailyPerInstall: "200", InfoModels: "a,b"}
	if err := s.PutServerInfo(ctx, in); err != nil {
		t.Fatalf("PutServerInfo() error = %v", err)
	}

	got, err := s.ServerInfo(ctx)
	if err != nil {
		t.Fatalf("ServerInfo() error = %v", err)
	}
	if len(got) != 2 || got[InfoDailyPerInstall] != "200" || got[InfoModels] != "a,b" {
		t.Fatalf("ServerInfo() = %v, want %v", got, in)
	}
}

func TestPutServerInfoOverwritesAndKeepsOthers(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()

	if err := s.PutServerInfo(ctx, map[string]string{InfoDailyPerInstall: "200", InfoImageTag: "old"}); err != nil {
		t.Fatalf("PutServerInfo() error = %v", err)
	}
	if err := s.PutServerInfo(ctx, map[string]string{InfoImageTag: "new"}); err != nil {
		t.Fatalf("second PutServerInfo() error = %v", err)
	}

	got, err := s.ServerInfo(ctx)
	if err != nil {
		t.Fatalf("ServerInfo() error = %v", err)
	}
	if got[InfoImageTag] != "new" || got[InfoDailyPerInstall] != "200" {
		t.Fatalf("ServerInfo() = %v", got)
	}
}

func TestServerInfoEmpty(t *testing.T) {
	s := newTestStore(t)

	got, err := s.ServerInfo(context.Background())
	if err != nil {
		t.Fatalf("ServerInfo() error = %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("ServerInfo() = %v, want empty", got)
	}
}
