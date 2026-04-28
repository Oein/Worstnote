// Package http wires the HTTP layer: router, middleware, and feature handlers.
package http

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	chimw "github.com/go-chi/chi/v5/middleware"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/oein/notee/server/internal/auth"
	mw "github.com/oein/notee/server/internal/http/middleware"
	syncpkg "github.com/oein/notee/server/internal/sync"
)

// Deps groups dependencies needed across handlers.
type Deps struct {
	Now    func() time.Time
	DB     *pgxpool.Pool
	Auth   *auth.Service
	Sync   *syncpkg.Service
	Issuer *auth.Issuer
}

// NewRouter builds the chi router. Always mounts /v1/health; auth + sync
// routes mount only when the corresponding services are non-nil (so
// router_test can keep its no-DB tests trivial).
func NewRouter(d Deps) http.Handler {
	r := chi.NewRouter()

	r.Use(chimw.RequestID)
	r.Use(chimw.RealIP)
	r.Use(chimw.Recoverer)
	r.Use(mw.RequestLogger())
	r.Use(chimw.Timeout(30 * time.Second))

	r.Route("/v1", func(r chi.Router) {
		r.Get("/health", healthHandler(d))

		if d.Auth != nil {
			r.Post("/auth/signup", d.Auth.Signup)
			r.Post("/auth/login", d.Auth.Login)
			r.Post("/auth/refresh", d.Auth.Refresh)
		}

		if d.Issuer != nil {
			r.Group(func(r chi.Router) {
				r.Use(auth.Middleware(d.Issuer))

				if d.Auth != nil {
					r.Post("/auth/logout", d.Auth.Logout)
				}
				if d.Sync != nil {
					r.Get("/sync/notes", d.Sync.ListNotes)
					r.Post("/sync/{noteId}/push", d.Sync.Push)
					r.Get("/sync/{noteId}/pull", d.Sync.Pull)
					r.Get("/sync/{noteId}/history", d.Sync.History)
					r.Get("/sync/{noteId}/history/{commitId}", d.Sync.HistorySnapshot)
					r.Post("/sync/{noteId}/history/{commitId}/restore", d.Sync.HistoryRestore)
					r.Get("/sync/{noteId}/conflicts/{sid}", d.Sync.GetConflict)
					r.Post("/sync/{noteId}/conflicts/{sid}/resolve", d.Sync.ResolveConflict)
				}
			})
		}
	})

	return r
}

func healthHandler(d Deps) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{
			"status": "ok",
			"now":    d.Now().UTC().Format(time.RFC3339Nano),
		})
	}
}

func writeJSON(w http.ResponseWriter, code int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(body)
}
