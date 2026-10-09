// Command pawlet-admin serves the owner-only dashboard over pawletd's
// database. Subcommands: serve (default), hash-password, dev-seed.
package main

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/ahmedsadman/pawlet/server/internal/admin"
	"github.com/ahmedsadman/pawlet/server/internal/devseed"
	"github.com/ahmedsadman/pawlet/server/internal/httpapi"
	"github.com/ahmedsadman/pawlet/server/internal/store"
)

const usage = `usage:
  pawlet-admin [serve]            serve the dashboard (configured by environment)
  pawlet-admin hash-password      read a password on stdin, print its argon2id hash
  pawlet-admin dev-seed --db PATH fill an EMPTY database with fake history`

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	cmd := "serve"
	if len(os.Args) > 1 {
		cmd = os.Args[1]
	}
	var err error
	switch cmd {
	case "serve":
		err = serve(logger)
	case "hash-password":
		err = hashPassword(os.Stdin, os.Stdout)
	case "dev-seed":
		err = devSeed(os.Args[2:], os.Stdout)
	default:
		fmt.Fprintln(os.Stderr, usage)
		os.Exit(2)
	}
	if err != nil {
		logger.Error("fatal", "error", err)
		os.Exit(1)
	}
}

func hashPassword(in io.Reader, out io.Writer) error {
	line, err := bufio.NewReader(in).ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return fmt.Errorf("read password: %w", err)
	}
	password := strings.TrimRight(line, "\r\n")
	if password == "" {
		return errors.New("empty password")
	}
	hash, err := admin.HashPassword(password)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintln(out, hash)
	return err
}

func devSeed(args []string, out io.Writer) error {
	fs := flag.NewFlagSet("dev-seed", flag.ContinueOnError)
	path := fs.String("db", "", "database file to fill (must have no installs)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *path == "" {
		return errors.New("dev-seed needs --db PATH")
	}
	sum, err := devseed.Seed(*path, time.Now(), time.Now().UnixNano())
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(out, "seeded %s: %d installs, %d session days, %d usage rows, %d counters (%s..%s)\n",
		*path, sum.Installs, sum.InstallDays, sum.Usage, sum.Counters, sum.From, sum.To)
	return err
}

func serve(logger *slog.Logger) error {
	cfg, err := admin.LoadConfig(os.LookupEnv)
	if err != nil {
		return err
	}
	_, trusted, err := net.ParseCIDR(cfg.TrustedProxyCIDR)
	if err != nil {
		return err
	}
	db, err := store.OpenExisting(cfg.DatabasePath)
	if errors.Is(err, store.ErrSchemaTooOld) {
		return fmt.Errorf("%w; start pawletd first so it migrates the database", err)
	}
	if err != nil {
		return err
	}
	defer func() { _ = db.Close() }()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	srv := admin.New(admin.Options{
		Store:         db,
		PasswordHash:  cfg.PasswordHash,
		SessionSecret: cfg.SessionSecret,
		TrustedProxy:  trusted,
		Logger:        logger,
		Now:           time.Now,
	})
	httpSrv := &http.Server{
		Addr:              cfg.Addr,
		Handler:           httpapi.Chain(srv.Handler(), httpapi.Recovery(logger), httpapi.RequestLogger(logger)),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
		BaseContext:       func(_ net.Listener) context.Context { return ctx },
	}

	errCh := make(chan error, 1)
	go func() {
		logger.Info("listening", "addr", httpSrv.Addr)
		if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	var serverErr error
	select {
	case serverErr = <-errCh:
	case <-ctx.Done():
		logger.Info("shutdown signal received")
	}
	shutdownCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
	defer cancel()
	if err := httpSrv.Shutdown(shutdownCtx); err != nil {
		logger.Error("shutdown failed", "error", err)
	}
	return serverErr
}
