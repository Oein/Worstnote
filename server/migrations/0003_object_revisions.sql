-- +goose Up
-- +goose StatementBegin

-- ============================================================================
-- PAGE_OBJECT_REVISIONS — git-style append-only log
-- One row per state change of a page_object. Each commit groups together all
-- revisions inserted between the previous commit and itself, so:
--   - "history" = SELECT * FROM note_commits ORDER BY created_at DESC
--   - "snapshot at commit X" = SELECT DISTINCT ON (object_id) * FROM
--       page_object_revisions WHERE rev <= commit.rev_to ORDER BY object_id, rev DESC
--   - "diff between commits A..B" = SELECT * FROM page_object_revisions
--       WHERE commit_id IN (...commits between A and B...)
-- page_objects stays as the materialized "current state" view for fast reads.
-- ============================================================================
CREATE TABLE page_object_revisions (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    object_id     UUID NOT NULL,
    note_id       UUID NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    page_id       UUID NOT NULL,
    layer_id      UUID NOT NULL,
    kind          TEXT NOT NULL,
    data          JSONB NOT NULL,
    bbox_minx     DOUBLE PRECISION,
    bbox_miny     DOUBLE PRECISION,
    bbox_maxx     DOUBLE PRECISION,
    bbox_maxy     DOUBLE PRECISION,
    rev           BIGINT NOT NULL,
    deleted       BOOLEAN NOT NULL DEFAULT FALSE,
    device_id     TEXT NOT NULL DEFAULT '',
    -- NULL until a commit groups this revision in. The COMMIT endpoint sweeps
    -- all NULLs for a note into the new commit row.
    commit_id     UUID REFERENCES note_commits(id) ON DELETE SET NULL,
    committed_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX page_object_revisions_object_idx
    ON page_object_revisions(object_id, rev DESC);
CREATE INDEX page_object_revisions_note_rev_idx
    ON page_object_revisions(note_id, rev);
CREATE INDEX page_object_revisions_uncommitted_idx
    ON page_object_revisions(note_id) WHERE commit_id IS NULL;
CREATE INDEX page_object_revisions_commit_idx
    ON page_object_revisions(commit_id);

-- Backfill: seed the revisions log with whatever is currently in page_objects
-- so existing notes still have *some* baseline that "snapshot at HEAD" can
-- reconstruct. These rows inherit the latest commit per note (best-effort)
-- and stay marked with that commit_id (not NULL) so a fresh commit doesn't
-- absorb pre-history rows.
INSERT INTO page_object_revisions
  (object_id, note_id, page_id, layer_id, kind, data,
   bbox_minx, bbox_miny, bbox_maxx, bbox_maxy,
   rev, deleted, committed_at, commit_id)
SELECT po.id, p.note_id, po.page_id, po.layer_id, po.kind, po.data,
       po.bbox_minx, po.bbox_miny, po.bbox_maxx, po.bbox_maxy,
       po.rev, po.deleted, po.updated_at,
       (SELECT c.id FROM note_commits c
        WHERE c.note_id = p.note_id
        ORDER BY c.created_at DESC LIMIT 1)
FROM page_objects po
JOIN pages p ON p.id = po.page_id;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE IF EXISTS page_object_revisions;
-- +goose StatementEnd
