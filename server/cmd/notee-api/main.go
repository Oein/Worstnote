// Package main is the entrypoint for the Notee API server.
package main

import (
	"context"
	"errors"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/oein/notee/server/internal/auth"
	"github.com/oein/notee/server/internal/config"
	"github.com/oein/notee/server/internal/db"
	httpapi "github.com/oein/notee/server/internal/http"
	syncpkg "github.com/oein/notee/server/internal/sync"
	"github.com/oein/notee/server/internal/storage"
	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"
)

func main() {
	if os.Getenv("LOG_FORMAT") != "json" {
		log.Logger = log.Output(zerolog.ConsoleWriter{Out: os.Stderr, TimeFormat: time.RFC3339})
	}

	cfg, err := config.Load()
	if err != nil {
		log.Fatal().Err(err).Msg("failed to load config")
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	pool, err := db.Open(ctx, cfg.DatabaseURL)
	if err != nil {
		log.Fatal().Err(err).Msg("postgres connect failed")
	}
	defer pool.Close()
	log.Info().Msg("postgres connected")

	issuer := auth.NewIssuer(cfg.JWTSecret, cfg.AccessTokenTTL)
	authSvc := auth.NewService(pool, issuer, cfg.RefreshTokenTTL)
	syncSvc := syncpkg.NewService(pool)

	// Wire asset storage (MinIO). Non-fatal if unavailable — assets endpoints
	// return 501 when Storage is nil, so the rest of the API keeps working.
	if store, err := storage.New(
		cfg.S3Endpoint, cfg.S3AccessKey, cfg.S3SecretKey, cfg.S3Bucket, cfg.S3UseSSL,
	); err != nil {
		log.Warn().Err(err).Msg("asset storage unavailable — PDF/image sync disabled")
	} else {
		syncSvc.Storage = store
		log.Info().Str("endpoint", cfg.S3Endpoint).Msg("asset storage connected")
	}

	router := httpapi.NewRouter(httpapi.Deps{
		Now:    time.Now,
		DB:     pool,
		Auth:   authSvc,
		Sync:   syncSvc,
		Issuer: issuer,
	})

	srv := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           router,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       60 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	go func() {
		log.Info().Str("addr", cfg.HTTPAddr).Msg("notee-api listening")
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal().Err(err).Msg("http server failed")
		}
	}()

	<-ctx.Done()
	log.Info().Msg("shutdown signal received")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Error().Err(err).Msg("graceful shutdown failed")
	}
	log.Info().Msg("notee-api stopped")
}
