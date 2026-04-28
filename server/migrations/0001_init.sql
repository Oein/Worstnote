-- +goose Up
-- +goose StatementBegin

-- Required extensions for UUID and case-insensitive emails.
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "citext";

-- ============================================================================
-- USERS
-- ============================================================================
CREATE TABLE users (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email           CITEXT UNIQUE,
    password_hash   TEXT,                       -- nullable for oauth-only accounts
    apple_sub       TEXT UNIQUE,
    google_sub      TEXT UNIQUE,
    display_name    TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================================
-- NOTES
-- A note is a collection of pages. scroll_axis is per-note user preference.
-- default_page_spec stores PageSpec JSON used when adding a new page if the
-- user picks "use note default".
-- ============================================================================
CREATE TABLE notes (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id            UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title               TEXT NOT NULL,
    scroll_axis         TEXT NOT NULL DEFAULT 'vertical'
                        CHECK (scroll_axis IN ('vertical', 'horizontal')),
    -- 'any' (default): finger/mouse/stylus all draw.
    -- 'stylusOnly': only Apple Pencil / S-Pen / Wacom draws; finger scrolls.
    input_draw_mode     TEXT NOT NULL DEFAULT 'any'
                        CHECK (input_draw_mode IN ('any', 'stylusOnly')),
    default_page_spec   JSONB NOT NULL,
    rev                 BIGINT NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX notes_owner_idx ON notes(owner_id);

-- ============================================================================
-- PAGES
-- Each page carries its own PageSpec (width/height/kind/background) so a note
-- can mix page sizes (e.g. PDF imports vary per-page).
-- ============================================================================
CREATE TABLE pages (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    note_id      UUID NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    idx          INT NOT NULL,
    spec         JSONB NOT NULL,
    rev          BIGINT NOT NULL DEFAULT 0,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (note_id, idx)
);
CREATE INDEX pages_note_idx ON pages(note_id);

-- ============================================================================
-- LAYERS
-- Pages always have at least one layer ("Default"). All page_objects live in
-- exactly one layer. z is render order (0 = bottom). Tape objects live in a
-- dedicated top layer by convention.
-- ============================================================================
CREATE TABLE layers (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    page_id      UUID NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
    z            INT NOT NULL,
    name         TEXT NOT NULL,
    visible      BOOLEAN NOT NULL DEFAULT TRUE,
    locked       BOOLEAN NOT NULL DEFAULT FALSE,
    opacity      REAL NOT NULL DEFAULT 1.0
                 CHECK (opacity >= 0 AND opacity <= 1),
    rev          BIGINT NOT NULL DEFAULT 0,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (page_id, z)
);
CREATE INDEX layers_page_idx ON layers(page_id);

-- ============================================================================
-- PAGE OBJECTS
-- Single-table-inheritance for stroke/shape/text/tape. data is the freezed
-- model JSON; bbox is denormalized for spatial selection (rect-select, lasso
-- broad-phase, viewport culling). deleted=true is a tombstone for sync.
-- ============================================================================
CREATE TABLE page_objects (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    page_id      UUID NOT NULL REFERENCES pages(id)  ON DELETE CASCADE,
    layer_id     UUID NOT NULL REFERENCES layers(id) ON DELETE CASCADE,
    kind         TEXT NOT NULL
                 CHECK (kind IN ('stroke', 'shape', 'text', 'tape')),
    data         JSONB NOT NULL,
    -- bbox stored as a [minx,miny,maxx,maxy] JSON array; PostGIS-free,
    -- queried via GIN expression index when sync grows.
    bbox_minx    DOUBLE PRECISION,
    bbox_miny    DOUBLE PRECISION,
    bbox_maxx    DOUBLE PRECISION,
    bbox_maxy    DOUBLE PRECISION,
    rev          BIGINT NOT NULL,
    deleted      BOOLEAN NOT NULL DEFAULT FALSE,
    created_by   UUID REFERENCES users(id),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX page_objects_page_layer_rev_idx
    ON page_objects(page_id, layer_id, rev);
CREATE INDEX page_objects_page_rev_idx
    ON page_objects(page_id, rev);
-- Spatial-ish index for bbox range queries used by selection.
CREATE INDEX page_objects_bbox_idx
    ON page_objects(page_id, bbox_minx, bbox_miny, bbox_maxx, bbox_maxy);

-- ============================================================================
-- ASSETS
-- PDF/image originals uploaded via S3/MinIO presigned PUT. Dedup by sha256.
-- ============================================================================
CREATE TABLE assets (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    sha256       BYTEA NOT NULL,
    object_key   TEXT NOT NULL,
    mime         TEXT NOT NULL,
    size_bytes   BIGINT NOT NULL,
    completed    BOOLEAN NOT NULL DEFAULT FALSE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (owner_id, sha256)
);

-- ============================================================================
-- SYNC CURSORS
-- Per (user, note, device) high-water mark for delta pull.
-- ============================================================================
CREATE TABLE sync_cursors (
    user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    note_id      UUID NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    device_id    TEXT NOT NULL,
    last_rev     BIGINT NOT NULL DEFAULT 0,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, note_id, device_id)
);

-- ============================================================================
-- USER PRESETS
-- Toolbar color/thickness slots (≤ 12 per user).
-- ============================================================================
CREATE TABLE user_presets (
    user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    slot         INT NOT NULL CHECK (slot >= 0 AND slot < 12),
    kind         TEXT NOT NULL CHECK (kind IN ('pen', 'highlighter', 'shape')),
    color_argb   INTEGER NOT NULL,
    width_pt     REAL NOT NULL,
    opacity      REAL NOT NULL DEFAULT 1.0
                 CHECK (opacity >= 0 AND opacity <= 1),
    PRIMARY KEY (user_id, slot)
);

-- ============================================================================
-- AUTH SESSIONS
-- Refresh tokens (rotating). Access tokens are short-lived JWTs and not stored.
-- ============================================================================
CREATE TABLE auth_sessions (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id           TEXT NOT NULL,
    refresh_token_hash  BYTEA NOT NULL,
    expires_at          TIMESTAMPTZ NOT NULL,
    revoked_at          TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_used_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX auth_sessions_user_device_idx ON auth_sessions(user_id, device_id);

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE IF EXISTS auth_sessions;
DROP TABLE IF EXISTS user_presets;
DROP TABLE IF EXISTS sync_cursors;
DROP TABLE IF EXISTS assets;
DROP TABLE IF EXISTS page_objects;
DROP TABLE IF EXISTS layers;
DROP TABLE IF EXISTS pages;
DROP TABLE IF EXISTS notes;
DROP TABLE IF EXISTS users;
-- +goose StatementEnd
