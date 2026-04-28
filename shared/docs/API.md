# Notee API (v1)

> **Status (P0)**: only `/v1/health` is live. The routes below are the contract that subsequent phases will fill in.

## Conventions
- Base URL: `https://api.notee.app` (or `http://localhost:8080` in dev).
- All bodies are JSON (UTF-8). Timestamps are RFC3339 with nanos in UTC.
- Auth: `Authorization: Bearer <access_token>` (JWT, 15 min). Refresh via `/v1/auth/refresh`.
- Idempotency: `X-Idempotency-Key` accepted on POSTs; the server stores the (key, user) result for 24h.
- Errors: JSON `{ "error": { "code": "snake_case", "message": "...", "details": {...} } }` with appropriate HTTP status.

## Endpoints

### Health
- `GET /v1/health` → `200 { "status": "ok", "now": "..." }`

### Auth (Phase A2+)
- `POST /v1/auth/signup`        — email + password → access/refresh tokens
- `POST /v1/auth/login`
- `POST /v1/auth/refresh`        — rotating refresh
- `POST /v1/auth/logout`
- `POST /v1/auth/oauth/apple`    — Phase A3
- `POST /v1/auth/oauth/google`   — Phase A4

### Notes
- `GET    /v1/notes`              — list owned notes
- `POST   /v1/notes`              — create
- `GET    /v1/notes/{id}`
- `PATCH  /v1/notes/{id}`         — title, scrollAxis, defaultPageSpec
- `DELETE /v1/notes/{id}`

### Pages
- `POST   /v1/notes/{id}/pages`         — append page, body has spec
- `PATCH  /v1/pages/{id}`               — spec, idx
- `DELETE /v1/pages/{id}`

### Layers
- `POST   /v1/pages/{id}/layers`
- `PATCH  /v1/layers/{id}`              — name, z, visible, locked, opacity
- `DELETE /v1/layers/{id}`

### Sync (Phase P9)
- `POST /v1/sync/{noteId}/push`         — see SYNC.md
- `GET  /v1/sync/{noteId}/pull?since=`  — delta since cursor

### Assets (PDF / Image)
- `POST /v1/assets:initiate`            — body `{ sha256, sizeBytes, mime }`, returns presigned PUT URL + `assetId`
- `POST /v1/assets:complete`            — body `{ assetId }`, server HEADs S3 and commits

## Status codes
| Code | Meaning |
|------|---------|
| 200  | OK |
| 201  | Created |
| 204  | No Content |
| 400  | Validation / shape error |
| 401  | Missing/invalid token |
| 403  | Authenticated but not authorized |
| 404  | Not found |
| 409  | Conflict (e.g. revision conflict) |
| 422  | Semantic error |
| 429  | Rate limited |
| 500  | Server error |
