package metrics

import (
	"context"
	"errors"
	"sort"
	"sync"
	"testing"
	"time"
)

type fakeSink struct {
	mu      sync.Mutex
	batches [][]Delta
	fail    bool
}

func (s *fakeSink) PersistCounters(_ context.Context, deltas []Delta) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.fail {
		return errors.New("sink down")
	}
	cp := append([]Delta(nil), deltas...)
	sort.Slice(cp, func(i, j int) bool {
		a, b := cp[i], cp[j]
		if a.Day != b.Day {
			return a.Day < b.Day
		}
		if a.Metric != b.Metric {
			return a.Metric < b.Metric
		}
		return a.Key < b.Key
	})
	s.batches = append(s.batches, cp)
	return nil
}

func (s *fakeSink) setFail(v bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.fail = v
}

func (s *fakeSink) batchCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.batches)
}

func (s *fakeSink) last() []Delta {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.batches) == 0 {
		return nil
	}
	return s.batches[len(s.batches)-1]
}

func fixedClock(t time.Time) func() time.Time { return func() time.Time { return t } }

func TestIncAggregatesByDayMetricKey(t *testing.T) {
	sink := &fakeSink{}
	r := New(sink, fixedClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC)))

	r.Inc(ClassifyOutcome, OK)
	r.Inc(ClassifyOutcome, OK)
	r.Inc(ClassifyOutcome, OK)
	r.Inc(ClassifyOutcome, Capacity)

	if err := r.Flush(context.Background()); err != nil {
		t.Fatalf("Flush() error = %v", err)
	}
	want := []Delta{
		{Day: "2026-10-09", Metric: ClassifyOutcome, Key: Capacity, Count: 1},
		{Day: "2026-10-09", Metric: ClassifyOutcome, Key: OK, Count: 3},
	}
	assertDeltas(t, sink.last(), want)
}

func TestIncUsesUTCDay(t *testing.T) {
	sink := &fakeSink{}
	dhaka := time.FixedZone("BST", 6*60*60)
	r := New(sink, fixedClock(time.Date(2026, 10, 9, 2, 0, 0, 0, dhaka)))

	r.Inc(SessionOutcome, OK)
	if err := r.Flush(context.Background()); err != nil {
		t.Fatalf("Flush() error = %v", err)
	}
	assertDeltas(t, sink.last(), []Delta{{Day: "2026-10-08", Metric: SessionOutcome, Key: OK, Count: 1}})
}

func TestFlushClearsPending(t *testing.T) {
	sink := &fakeSink{}
	r := New(sink, fixedClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC)))

	r.Inc(Model, "m1")
	if err := r.Flush(context.Background()); err != nil {
		t.Fatalf("Flush() error = %v", err)
	}
	if err := r.Flush(context.Background()); err != nil {
		t.Fatalf("second Flush() error = %v", err)
	}
	if got := sink.batchCount(); got != 1 {
		t.Fatalf("batches = %d, want 1 (empty flush must not call the sink)", got)
	}
}

func TestFlushFailureMergesBack(t *testing.T) {
	sink := &fakeSink{fail: true}
	r := New(sink, fixedClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC)))

	r.Inc(Category, "bill")
	r.Inc(Category, "bill")
	if err := r.Flush(context.Background()); err == nil {
		t.Fatal("Flush() error = nil, want sink failure")
	}

	sink.setFail(false)
	r.Inc(Category, "bill")
	if err := r.Flush(context.Background()); err != nil {
		t.Fatalf("Flush() error = %v", err)
	}
	assertDeltas(t, sink.last(), []Delta{{Day: "2026-10-09", Metric: Category, Key: "bill", Count: 3}})
}

func TestDayRolloverSplitsCounts(t *testing.T) {
	sink := &fakeSink{}
	now := time.Date(2026, 10, 9, 23, 59, 59, 0, time.UTC)
	r := New(sink, func() time.Time { return now })

	r.Inc(ClassifyOutcome, OK)
	now = now.Add(2 * time.Second)
	r.Inc(ClassifyOutcome, OK)

	if err := r.Flush(context.Background()); err != nil {
		t.Fatalf("Flush() error = %v", err)
	}
	assertDeltas(t, sink.last(), []Delta{
		{Day: "2026-10-09", Metric: ClassifyOutcome, Key: OK, Count: 1},
		{Day: "2026-10-10", Metric: ClassifyOutcome, Key: OK, Count: 1},
	})
}

func TestConcurrentInc(t *testing.T) {
	sink := &fakeSink{}
	r := New(sink, fixedClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC)))

	const goroutines, each = 50, 100
	var wg sync.WaitGroup
	for i := 0; i < goroutines; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < each; j++ {
				r.Inc(ClassifyOutcome, OK)
			}
		}()
	}
	wg.Wait()

	if err := r.Flush(context.Background()); err != nil {
		t.Fatalf("Flush() error = %v", err)
	}
	assertDeltas(t, sink.last(), []Delta{
		{Day: "2026-10-09", Metric: ClassifyOutcome, Key: OK, Count: goroutines * each},
	})
}

func TestRunFlusherFlushesOnCancel(t *testing.T) {
	sink := &fakeSink{}
	r := New(sink, fixedClock(time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC)))
	r.Inc(ClassifyOutcome, OK)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		r.RunFlusher(ctx, time.Hour, nil)
		close(done)
	}()
	cancel()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("RunFlusher did not return after cancel")
	}
	assertDeltas(t, sink.last(), []Delta{{Day: "2026-10-09", Metric: ClassifyOutcome, Key: OK, Count: 1}})
}

func assertDeltas(t *testing.T, got, want []Delta) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("deltas = %+v, want %+v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("deltas = %+v, want %+v", got, want)
		}
	}
}
