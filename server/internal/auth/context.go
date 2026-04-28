package auth

import (
	"context"
	"net/http"
	"strings"
)

type ctxKey int

const claimsKey ctxKey = 0

// WithClaims stashes the verified claims for the rest of the request.
func WithClaims(ctx context.Context, c *Claims) context.Context {
	return context.WithValue(ctx, claimsKey, c)
}

// ClaimsFromContext retrieves the claims placed by [Middleware].
func ClaimsFromContext(ctx context.Context) (*Claims, bool) {
	c, ok := ctx.Value(claimsKey).(*Claims)
	return c, ok
}

// Middleware verifies the Bearer token and stashes claims onto the context.
// Unauthenticated requests get 401.
func Middleware(issuer *Issuer) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			h := r.Header.Get("Authorization")
			if !strings.HasPrefix(h, "Bearer ") {
				writeErr(w, http.StatusUnauthorized, "missing_token", "")
				return
			}
			token := strings.TrimPrefix(h, "Bearer ")
			claims, err := issuer.Verify(token)
			if err != nil {
				writeErr(w, http.StatusUnauthorized, "invalid_token", "")
				return
			}
			next.ServeHTTP(w, r.WithContext(WithClaims(r.Context(), claims)))
		})
	}
}
