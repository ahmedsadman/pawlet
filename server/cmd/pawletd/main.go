// Command pawletd serves the Pawlet attestation and LLM proxy API.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/ahmedsadman/pawlet/server/internal/attest"
	"github.com/ahmedsadman/pawlet/server/internal/config"
	"github.com/ahmedsadman/pawlet/server/internal/httpapi"
	"github.com/ahmedsadman/pawlet/server/internal/llm"
	"github.com/ahmedsadman/pawlet/server/internal/metrics"
	"github.com/ahmedsadman/pawlet/server/internal/quota"
	"github.com/ahmedsadman/pawlet/server/internal/store"
	"github.com/ahmedsadman/pawlet/server/internal/token"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	if err := run(logger); err != nil {
		logger.Error("fatal", "error", err)
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	// 1. Load configuration.
	cfg, err := config.Load(os.LookupEnv)
	if err != nil {
		return err
	}

	// 2. Create a cancellable context from signals.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// 3. Open the database.
	db, err := store.Open(cfg.DatabasePath)
	if err != nil {
		return err
	}
	defer db.Close()

	// 4. Parse the trusted proxy CIDR for client IP extraction.
	_, trustedProxy, err := net.ParseCIDR(cfg.TrustedProxyCIDR)
	if err != nil {
		return err
	}

	// 5. Build the Google integrity decoder.
	decoder, err := attest.NewGoogleDecoder(ctx, cfg.ServiceAccountPath, cfg.PackageName)
	if err != nil {
		return err
	}

	// 6. Build the quota limiter with a store-backed Sink adapter.
	sink := &storeSink{store: db}
	limiter := quota.New(
		quota.Limits{
			Daily:       cfg.DailyPerInstall,
			Burst:       cfg.BurstPerMin,
			GlobalDaily: cfg.GlobalDailyCap,
		},
		sink,
		time.Now,
	)

	// 7. Hydrate the limiter before serving requests. Without this, every restart
	// resets counters to zero, which would let a crashing service ignore global
	// daily caps entirely.
	if err := limiter.Hydrate(ctx); err != nil {
		return err
	}

	// 8. Start the quota flusher via a WaitGroup so the shutdown sequence can
	// wait for it before running the final flushes. Without the wait, a flusher
	// could still be writing when main's final flush runs (or worse, when defer
	// db.Close() fires).
	var flushers sync.WaitGroup
	flushers.Add(1)
	go func() {
		defer flushers.Done()
		limiter.RunFlusher(ctx, 10*time.Second, logger)
	}()

	// 8a. Publish the effective limits so the admin dashboard can show them
	// without its own copy of this configuration.
	if err := db.PutServerInfo(ctx, map[string]string{
		store.InfoDailyPerInstall: strconv.Itoa(cfg.DailyPerInstall),
		store.InfoBurstPerMin:     strconv.Itoa(cfg.BurstPerMin),
		store.InfoGlobalDailyCap:  strconv.Itoa(cfg.GlobalDailyCap),
		store.InfoModels:          strings.Join(cfg.Models, ","),
		store.InfoStartedAt:       strconv.FormatInt(time.Now().Unix(), 10),
		store.InfoImageTag:        cfg.ImageTag,
	}); err != nil {
		return err
	}

	// 8b. Start the metrics recorder. Like the quota limiter it flushes on an
	// interval, so handlers only ever touch memory.
	recorder := metrics.New(&counterSink{store: db}, time.Now)
	flushers.Add(1)
	go func() {
		defer flushers.Done()
		recorder.RunFlusher(ctx, 10*time.Second, logger)
	}()

	// 9. Build the challenge store and its per-IP rate limiter. Start a janitor
	// that cleans both.
	challenges := attest.NewChallenges(2*time.Minute, time.Now)
	challengeLimiter := httpapi.NewChallengeLimiter(cfg.ChallengePerIPHour)
	go func() {
		ticker := time.NewTicker(time.Minute)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				challenges.Prune()
				challengeLimiter.Prune()
			case <-ctx.Done():
				return
			}
		}
	}()

	// 10. Build the session token issuer.
	issuer := token.New(cfg.JWTSecret, 24*time.Hour)

	// 11. Build the LLM client.
	llmClient := &llm.Client{
		// Belt-and-braces: Classify already derives a 2-minute context, but a
		// transport ceiling means a leaked context cannot hang a connection.
		HTTP:     &http.Client{Timeout: 3 * time.Minute},
		Endpoint: llm.DefaultEndpoint,
		APIKey:   cfg.OpenRouterAPIKey,
		Models:   cfg.Models,
		Timeout:  2 * time.Minute,
	}

	// 12. Assemble the handlers.
	handlers := httpapi.Handlers{
		Session: &httpapi.SessionHandler{
			Challenges: challenges,
			Decoder:    decoder,
			Issuer:     issuer,
			Store:      db,
			Policy: attest.Policy{
				PackageName: cfg.PackageName,
				CertDigests: cfg.CertSHA256Digests,
				MaxAge:      5 * time.Minute,
			},
			Now:              time.Now,
			Logger:           logger,
			ChallengeLimiter: challengeLimiter,
			TrustedProxy:     trustedProxy,
			Metrics:          recorder,
		},
		Classify: &httpapi.ClassifyHandler{
			Classifier: llmClient,
			Issuer:     issuer,
			Store:      db,
			Limiter:    limiter,
			Now:        time.Now,
			Logger:     logger,
			Metrics:    recorder,
		},
		Bundle: httpapi.NewBundleHandler(cfg.Models),
		Health: db,
		Logger: logger,
	}

	// 13. Build the handler chain: Recovery wraps everything so it catches panics
	// from the logger middleware too.
	handler := httpapi.Chain(
		httpapi.NewRouter(handlers),
		httpapi.Recovery(logger),
		httpapi.RequestLogger(logger),
	)

	// 14. Build the HTTP server. WriteTimeout is deliberately absent: classify
	// calls inherit a 2-minute ceiling from the LLM client, and an http.Server
	// WriteTimeout below that would cut off legitimate slow calls mid-stream.
	srv := &http.Server{
		Addr:              cfg.Addr,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		BaseContext: func(_ net.Listener) context.Context {
			return ctx
		},
	}

	// 15. Start the server in a background goroutine.
	errCh := make(chan error, 1)
	go func() {
		logger.Info("listening", "addr", srv.Addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	// 16. Wait for a shutdown signal or server failure. On server failure, cancel
	// ctx so both flushers exit cleanly, then continue through the same shutdown
	// sequence (graceful shutdown, wait for flushers, final flushes) as the
	// signal path. The server error is returned at the end.
	var serverErr error
	select {
	case serverErr = <-errCh:
		logger.Error("server failed", "error", serverErr)
		stop()
	case <-ctx.Done():
		logger.Info("shutdown signal received")
	}

	// 17. Graceful shutdown with a 30-second timeout. Use WithoutCancel so the
	// shutdown context is not already cancelled.
	shutdownCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("shutdown failed", "error", err)
	}

	// 18. Wait for both flushers to exit so they are not writing when the final
	// flushes run (or worse, when defer db.Close() fires). Then do the final
	// flushes so the last counters are persisted. Use WithoutCancel again so
	// the flush context is valid even though ctx is already cancelled. Metrics
	// are flushed even if quota fails; losing them is not worth a non-zero
	// exit, losing quota is.
	flushers.Wait()
	quotaErr := limiter.Flush(context.WithoutCancel(ctx))
	if quotaErr != nil {
		logger.Error("final flush failed", "error", quotaErr)
	}
	if err := recorder.Flush(context.WithoutCancel(ctx)); err != nil {
		logger.Error("final metrics flush failed", "error", err)
	}

	// 19. Return the server error if one happened, otherwise a quota flush error.
	if serverErr != nil {
		return serverErr
	}
	if quotaErr != nil {
		return quotaErr
	}

	logger.Info("shutdown complete")
	return nil
}

// storeSink adapts store.Store to quota.Sink, decoupling the quota package from
// any particular database.
type storeSink struct {
	store *store.Store
}

func (s *storeSink) PersistUsage(ctx context.Context, deltas []quota.Delta) error {
	// Convert quota.Delta to store.UsageDelta.
	storeDeltas := make([]store.UsageDelta, len(deltas))
	for i, d := range deltas {
		storeDeltas[i] = store.UsageDelta{
			IDHash: d.IDHash,
			Day:    d.Day,
			Calls:  d.Calls,
			Tokens: d.Tokens,
		}
	}
	return s.store.AddUsage(ctx, storeDeltas)
}

func (s *storeSink) LoadUsage(ctx context.Context, day string) (map[string]int64, error) {
	return s.store.UsageForDay(ctx, day)
}

// counterSink adapts store.Store to metrics.Sink.
type counterSink struct {
	store *store.Store
}

func (s *counterSink) PersistCounters(ctx context.Context, deltas []metrics.Delta) error {
	storeDeltas := make([]store.CounterDelta, len(deltas))
	for i, d := range deltas {
		storeDeltas[i] = store.CounterDelta{Day: d.Day, Metric: d.Metric, Key: d.Key, Count: d.Count}
	}
	return s.store.AddCounters(ctx, storeDeltas)
}
