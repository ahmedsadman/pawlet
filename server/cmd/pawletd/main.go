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
	"syscall"
	"time"

	"github.com/ahmedsadman/pawlet/server/internal/attest"
	"github.com/ahmedsadman/pawlet/server/internal/config"
	"github.com/ahmedsadman/pawlet/server/internal/httpapi"
	"github.com/ahmedsadman/pawlet/server/internal/llm"
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

	// 4. Parse the trusted proxy CIDR for client IP extraction. Task 18 wires this
	// into the SessionHandler for per-IP challenge rate limiting.
	_, _, err = net.ParseCIDR(cfg.TrustedProxyCIDR)
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

	// 8. Start the limiter's background flusher.
	go limiter.RunFlusher(ctx, 10*time.Second, logger)

	// 9. Build the challenge store and start its janitor.
	challenges := attest.NewChallenges(2*time.Minute, time.Now)
	go challenges.RunJanitor(ctx, time.Minute)

	// 10. Build the session token issuer.
	issuer := token.New(cfg.JWTSecret, 24*time.Hour)

	// 11. Build the LLM client.
	llmClient := &llm.Client{
		HTTP:     &http.Client{},
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
			Now:    time.Now,
			Logger: logger,
		},
		Classify: &httpapi.ClassifyHandler{
			Classifier: &classifierAdapter{client: llmClient},
			Issuer:     issuer,
			Store:      db,
			Limiter:    limiter,
			Now:        time.Now,
			Logger:     logger,
		},
		Bundle: httpapi.NewBundleHandler(cfg.Models),
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

	// 16. Wait for a shutdown signal or server failure.
	select {
	case err := <-errCh:
		return err
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

	// 18. Final flush so the last counters are persisted. Use WithoutCancel again
	// so the flush context is valid even though ctx is already cancelled.
	if err := limiter.Flush(context.WithoutCancel(ctx)); err != nil {
		logger.Error("final flush failed", "error", err)
		return err
	}

	logger.Info("shutdown complete")
	return nil
}

// classifierAdapter adapts llm.Client to httpapi.Classifier. The interface
// accepts `any` for the context so test doubles can avoid creating a real
// context.Context, but the production client requires the concrete type.
type classifierAdapter struct {
	client *llm.Client
}

func (a *classifierAdapter) Classify(ctx any, in llm.Request) (llm.Response, error) {
	return a.client.Classify(ctx.(context.Context), in)
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
