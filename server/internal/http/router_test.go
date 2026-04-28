package http

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestHealthEndpoint(t *testing.T) {
	fixed := time.Date(2026, 4, 26, 12, 0, 0, 0, time.UTC)
	r := NewRouter(Deps{Now: func() time.Time { return fixed }})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/health", nil)
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}

	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("invalid json: %v", err)
	}
	if body["status"] != "ok" {
		t.Fatalf("expected status=ok, got %v", body["status"])
	}
	if body["now"] != fixed.Format(time.RFC3339Nano) {
		t.Fatalf("expected fixed now, got %v", body["now"])
	}
}

func TestUnknownRouteIs404(t *testing.T) {
	r := NewRouter(Deps{Now: time.Now})
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/nope", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", rec.Code)
	}
}
