# Notee

Cross-platform handwriting app for **macOS, iPhone, Android** (iPad to follow).
Pen with pressure/tilt, two erasers (stroke + area), highlighter, text boxes,
rect/lasso selection, △/□/○ shapes (long-press snap on mobile, Shift on macOS),
mnemonic tape, vertical/horizontal page scroll, per-page page sizes (PDF
imports preserve native sizes), layers, a fully customizable toolbar
(4-edge dock + floating), and a **pen-only drawing mode** (palm rejection —
only Apple Pencil / S-Pen / Wacom draws; finger gestures scroll the page).

> Status: **P0 skeleton** — repo wired up, Go API serving `/v1/health`, schema
> migration ready, Flutter client structure with pure-Dart engine helpers.
> See [`/Users/oein/.claude/plans/ipad-macos-iphone-android-twinkling-volcano.md`](./)
> for the full implementation plan.

## Repository layout

```
Notee/
├── client/        # Flutter app (macOS/iOS/Android)
├── server/        # Go API + migrations + deploy assets
│   ├── deploy/
│   │   ├── Dockerfile
│   │   ├── docker-compose.dev.yml
│   │   └── truenas/        ← TrueNAS Scale 24.10+ deployment
│   └── migrations/
└── shared/        # JSON Schema for the wire format + docs
    ├── proto/
    └── docs/
```

## Quick start

### Prerequisites

| Need | Used for |
|---|---|
| Go 1.25+ | building the server |
| Flutter 3.22+ (channel stable) | building the client |
| Docker Desktop *or* a TrueNAS Scale box | running Postgres + MinIO |
| `goose` (`go install github.com/pressly/goose/v3/cmd/goose@latest`) | running migrations |

> macOS: install Flutter via the official tarball or `brew install --cask flutter`.

### 1. Bring up the dev infra

```sh
docker compose -f server/deploy/docker-compose.dev.yml up -d
goose -dir server/migrations postgres \
  "postgres://notee:notee@localhost:5432/notee?sslmode=disable" up
```

MinIO console: <http://localhost:9001> (`minioadmin` / `minioadmin`).

### 2. Run the server

```sh
cd server
go run ./cmd/notee-api
# in another shell
curl -s localhost:8080/v1/health
```

### 3. Run the client

```sh
cd client
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # generates freezed/drift code
flutter run -d macos    # or: -d <ios sim id>, -d <android emulator id>
```

The default screen shows one A4 page with a draggable left toolbar; drawing
with mouse / Apple Pencil / S-Pen produces strokes immediately.

## Deploy the backend on TrueNAS Scale

See [`server/deploy/truenas/README.md`](./server/deploy/truenas/README.md).
The bundled compose file pins persistence to TrueNAS datasets (so snapshots
cover everything), runs Postgres + MinIO + the API, and includes a one-shot
migration job and a Caddy reverse-proxy starter for TLS.

## Tests

```sh
# server
cd server && go test -race ./...

# client
cd client && flutter test
```

## License

MIT — see `LICENSE` (TBD).
