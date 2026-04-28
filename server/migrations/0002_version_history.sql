-- +goose Up
-- +goose StatementBegin

-- ============================================================================
-- NOTE_COMMITS
-- A lightweight commit record created after every successful push.
-- Stores the high-water rev so the server can reconstruct any historical
-- snapshot by querying page_objects WHERE rev <= rev_to.
-- ============================================================================
CREATE TABLE note_commits (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    note_id     UUID NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    parent_id   UUID REFERENCES note_commits(id),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id   TEXT NOT NULL DEFAULT '',
    message     TEXT NOT NULL DEFAULT '',   -- auto-generated human description
    rev_to      BIGINT NOT NULL,            -- snapshot = all objects with rev <= rev_to
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX note_commits_note_idx ON note_commits(note_id, created_at DESC);

-- ============================================================================
-- CONFLICT_SESSIONS
-- Created when a push contains objects modified on the server since the
-- client's last sync rev. The client must resolve each item before the
-- conflicting objects are written.
-- Non-conflicting objects from the same push are applied immediately.
-- ============================================================================
CREATE TABLE conflict_sessions (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    note_id     UUID NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id   TEXT NOT NULL DEFAULT '',
    base_rev    BIGINT NOT NULL,    -- lastServerRev the client sent
    status      TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'resolved', 'abandoned')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at TIMESTAMPTZ
);

CREATE INDEX conflict_sessions_note_idx ON conflict_sessions(note_id, status, created_at DESC);

-- ============================================================================
-- CONFLICT_ITEMS
-- One row per conflicting object within a session.
-- local_data = full objectChange JSON the client pushed.
-- server_data = current page_objects row's data JSON.
-- ============================================================================
CREATE TABLE conflict_items (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id  UUID NOT NULL REFERENCES conflict_sessions(id) ON DELETE CASCADE,
    object_id   TEXT NOT NULL,          -- page_objects.id (UUID stored as text)
    local_data  JSONB,                  -- what the client wanted to write
    server_data JSONB,                  -- what the server currently has
    resolution  TEXT CHECK (resolution IN ('local', 'server', 'deleted')),
    resolved_at TIMESTAMPTZ
);

CREATE INDEX conflict_items_session_idx ON conflict_items(session_id);

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE IF EXISTS conflict_items;
DROP TABLE IF EXISTS conflict_sessions;
DROP TABLE IF EXISTS note_commits;
-- +goose StatementEnd
