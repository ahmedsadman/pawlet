// Command pawletd serves the Pawlet attestation and LLM proxy API.
package main

import (
	"log/slog"
	"net/http"
	"os"

	"github.com/ahmedsadman/pawlet/server/internal/httpapi"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	srv := &http.Server{Addr: ":8080", Handler: httpapi.NewRouter()}
	logger.Info("listening", "addr", srv.Addr)
	if err := srv.ListenAndServe(); err != nil {
		logger.Error("server stopped", "err", err)
		os.Exit(1)
	}
}
