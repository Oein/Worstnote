// Package sync implements the delta-sync push/pull endpoints and version-history/conflict APIs.
//
// Conflict detection is rev-based: an object is conflicting when the server's
// copy has rev > lastServerRev (modified on the server after the client last
// synced). Non-conflicting objects are applied immediately. Conflicting objects
// are stored in a conflict_session/conflict_items and returned to the client for
// resolution. After each successful push a note_commit is created so history can
// be browsed and restored.
package sync

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/oein/notee/server/internal/auth"
)

type Service struct {
	DB *pgxpool.Pool
}

func NewService(db *pgxpool.Pool) *Service { return &Service{DB: db} }

// ───── Wire types ────────────────────────────────────────────────────────

type pushReq struct {
	LastServerRev int64          `json:"lastServerRev"`
	Note          *noteMeta      `json:"note,omitempty"`
	Pages         []pageMeta     `json:"pages,omitempty"`
	Layers        []layerMeta    `json:"layers,omitempty"`
	Changes       []objectChange `json:"changes"`
}

type noteMeta struct {
	ID              string          `json:"id"`
	Title           string          `json:"title"`
	ScrollAxis      string          `json:"scrollAxis"`
	InputDrawMode   string          `json:"inputDrawMode"`
	DefaultPageSpec json.RawMessage `json:"defaultPageSpec"`
	Rev             int64           `json:"rev"`
	UpdatedAt       time.Time       `json:"updatedAt"`
}

type pageMeta struct {
	ID        string          `json:"id"`
	NoteID    string          `json:"noteId"`
	Index     int             `json:"index"`
	Spec      json.RawMessage `json:"spec"`
	Rev       int64           `json:"rev"`
	UpdatedAt time.Time       `json:"updatedAt"`
	Deleted   bool            `json:"deleted"`
}

type layerMeta struct {
	ID        string    `json:"id"`
	PageID    string    `json:"pageId"`
	Z         int       `json:"z"`
	Name      string    `json:"name"`
	Visible   bool      `json:"visible"`
	Locked    bool      `json:"locked"`
	Opacity   float64   `json:"opacity"`
	Rev       int64     `json:"rev"`
	Deleted   bool      `json:"deleted"`
	UpdatedAt time.Time `json:"updatedAt"`
}

type objectChange struct {
	ID        string          `json:"id"`
	PageID    string          `json:"pageId"`
	LayerID   string          `json:"layerId"`
	Kind      string          `json:"kind"` // stroke|shape|text|tape
	Data      json.RawMessage `json:"data"`
	Bbox      *[4]float64     `json:"bbox,omitempty"`
	Rev       int64           `json:"rev"`
	Deleted   bool            `json:"deleted"`
	UpdatedAt time.Time       `json:"updatedAt"`
	DeviceID  string          `json:"deviceId"`
}

type pushResp struct {
	ServerRev         int64              `json:"serverRev"`
	Accepted          []acceptedObject   `json:"accepted"`
	Conflicts         []conflictedObject `json:"conflicts"`
	ConflictSessionID string             `json:"conflictSessionId,omitempty"`
}

type acceptedObject struct {
	ID        string `json:"id"`
	ServerRev int64  `json:"serverRev"`
}

type conflictedObject struct {
	ID            string          `json:"id"`
	Winner        string          `json:"winner"` // "server"
	ServerVersion json.RawMessage `json:"serverVersion"`
}

type pullResp struct {
	Cursor  int64          `json:"cursor"`
	Note    *noteMeta      `json:"note,omitempty"`
	Pages   []pageMeta     `json:"pages,omitempty"`
	Layers  []layerMeta    `json:"layers,omitempty"`
	Changes []objectChange `json:"changes"`
	More    bool           `json:"more"`
}

// History types.

type historyEntry struct {
	ID        string    `json:"id"`
	ParentID  string    `json:"parentId,omitempty"`
	Message   string    `json:"message"`
	DeviceID  string    `json:"deviceId"`
	RevTo     int64     `json:"revTo"`
	CreatedAt time.Time `json:"createdAt"`
}

type conflictDetail struct {
	ID        string               `json:"id"`
	NoteID    string               `json:"noteId"`
	BaseRev   int64                `json:"baseRev"`
	Status    string               `json:"status"`
	CreatedAt time.Time            `json:"createdAt"`
	Items     []conflictItemDetail `json:"items"`
}

type conflictItemDetail struct {
	ID         string          `json:"id"`
	ObjectID   string          `json:"objectId"`
	LocalData  json.RawMessage `json:"localData"`
	ServerData json.RawMessage `json:"serverData"`
	Resolution string          `json:"resolution,omitempty"`
}

type resolveReq struct {
	Resolutions []itemResolution `json:"resolutions"`
}

type itemResolution struct {
	ItemID     string `json:"itemId"`
	Resolution string `json:"resolution"` // local | server | deleted
}

// ───── List notes ─────────────────────────────────────────────────────────

type noteSummary struct {
	ID        string    `json:"id"`
	Title     string    `json:"title"`
	UpdatedAt time.Time `json:"updatedAt"`
}

func (s *Service) ListNotes(w http.ResponseWriter, r *http.Request) {
	c, _ := auth.ClaimsFromContext(r.Context())
	rows, err := s.DB.Query(r.Context(),
		`SELECT id, title, updated_at FROM notes WHERE owner_id=$1 ORDER BY updated_at DESC`,
		c.UserID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "query", err.Error())
		return
	}
	defer rows.Close()
	var notes []noteSummary
	for rows.Next() {
		var n noteSummary
		if err := rows.Scan(&n.ID, &n.Title, &n.UpdatedAt); err == nil {
			notes = append(notes, n)
		}
	}
	if notes == nil {
		notes = []noteSummary{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"notes": notes})
}

// ───── Push ───────────────────────────────────────────────────────────────

func (s *Service) Push(w http.ResponseWriter, r *http.Request) {
	c, _ := auth.ClaimsFromContext(r.Context())
	noteID := chi.URLParam(r, "noteId")

	var req pushReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid_body", err.Error())
		return
	}

	tx, err := s.DB.BeginTx(r.Context(), pgx.TxOptions{})
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "tx_begin", err.Error())
		return
	}
	defer tx.Rollback(r.Context())

	// Verify note ownership / create on first push.
	if err := upsertOwnedNote(r.Context(), tx, c.UserID, noteID, req.Note); err != nil {
		writeErr(w, http.StatusForbidden, "note_owner_mismatch", err.Error())
		return
	}

	// Pages & layers metas.
	for _, p := range req.Pages {
		if _, err := tx.Exec(r.Context(),
			`INSERT INTO pages(id, note_id, idx, spec, rev, updated_at)
			 VALUES($1,$2,$3,$4,$5,$6)
			 ON CONFLICT(id) DO UPDATE SET idx=EXCLUDED.idx, spec=EXCLUDED.spec,
			   rev=EXCLUDED.rev, updated_at=EXCLUDED.updated_at
			 WHERE pages.updated_at <= EXCLUDED.updated_at`,
			p.ID, p.NoteID, p.Index, []byte(p.Spec), p.Rev, p.UpdatedAt); err != nil {
			writeErr(w, http.StatusInternalServerError, "pages_upsert", err.Error())
			return
		}
		if p.Deleted {
			_, _ = tx.Exec(r.Context(), `DELETE FROM pages WHERE id=$1`, p.ID)
		}
	}
	for _, l := range req.Layers {
		if _, err := tx.Exec(r.Context(),
			`INSERT INTO layers(id, page_id, z, name, visible, locked, opacity, rev, updated_at)
			 VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)
			 ON CONFLICT(id) DO UPDATE SET z=EXCLUDED.z, name=EXCLUDED.name,
			   visible=EXCLUDED.visible, locked=EXCLUDED.locked, opacity=EXCLUDED.opacity,
			   rev=EXCLUDED.rev, updated_at=EXCLUDED.updated_at
			 WHERE layers.updated_at <= EXCLUDED.updated_at`,
			l.ID, l.PageID, l.Z, l.Name, l.Visible, l.Locked, l.Opacity, l.Rev,
			nullableTime(l.UpdatedAt)); err != nil {
			writeErr(w, http.StatusInternalServerError, "layers_upsert", err.Error())
			return
		}
		if l.Deleted {
			_, _ = tx.Exec(r.Context(), `DELETE FROM layers WHERE id=$1`, l.ID)
		}
	}

	// Object changes — rev-based conflict detection.
	resp := pushResp{
		Accepted:  []acceptedObject{},
		Conflicts: []conflictedObject{},
	}

	// pendingConflict holds data for creating a conflict_session later.
	type pendingConflict struct {
		objectID   string
		localData  json.RawMessage
		serverData json.RawMessage
	}
	var pending []pendingConflict

	for _, ch := range req.Changes {
		var existingData []byte
		var existingRev int64
		var existingUpdatedAt *time.Time
		row := tx.QueryRow(r.Context(),
			`SELECT updated_at, data, rev FROM page_objects WHERE id=$1`, ch.ID)
		_ = row.Scan(&existingUpdatedAt, &existingData, &existingRev)

		// Rev-based conflict: server modified this object after client's last sync.
		if existingUpdatedAt != nil && existingRev > req.LastServerRev {
			resp.Conflicts = append(resp.Conflicts, conflictedObject{
				ID:            ch.ID,
				Winner:        "server",
				ServerVersion: json.RawMessage(existingData),
			})
			pending = append(pending, pendingConflict{
				objectID:   ch.ID,
				localData:  ch.Data,
				serverData: json.RawMessage(existingData),
			})
			continue
		}

		// Allocate next monotonic rev.
		var newRev int64
		if err := tx.QueryRow(r.Context(),
			`SELECT COALESCE(MAX(rev),0)+1 FROM page_objects`).Scan(&newRev); err != nil {
			writeErr(w, http.StatusInternalServerError, "rev_alloc", err.Error())
			return
		}
		var bboxMinX, bboxMinY, bboxMaxX, bboxMaxY *float64
		if ch.Bbox != nil {
			bboxMinX = &ch.Bbox[0]
			bboxMinY = &ch.Bbox[1]
			bboxMaxX = &ch.Bbox[2]
			bboxMaxY = &ch.Bbox[3]
		}
		if _, err := tx.Exec(r.Context(),
			`INSERT INTO page_objects(id, page_id, layer_id, kind, data,
				bbox_minx, bbox_miny, bbox_maxx, bbox_maxy, rev, deleted, created_by, updated_at)
			 VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)
			 ON CONFLICT(id) DO UPDATE SET data=EXCLUDED.data,
			   bbox_minx=EXCLUDED.bbox_minx, bbox_miny=EXCLUDED.bbox_miny,
			   bbox_maxx=EXCLUDED.bbox_maxx, bbox_maxy=EXCLUDED.bbox_maxy,
			   rev=EXCLUDED.rev, deleted=EXCLUDED.deleted, updated_at=EXCLUDED.updated_at`,
			ch.ID, ch.PageID, ch.LayerID, ch.Kind, []byte(ch.Data),
			bboxMinX, bboxMinY, bboxMaxX, bboxMaxY, newRev, ch.Deleted,
			c.UserID, ch.UpdatedAt); err != nil {
			writeErr(w, http.StatusInternalServerError, "object_upsert", err.Error())
			return
		}
		resp.Accepted = append(resp.Accepted, acceptedObject{ID: ch.ID, ServerRev: newRev})
		if newRev > resp.ServerRev {
			resp.ServerRev = newRev
		}
	}

	// Create conflict session if any conflicts exist.
	if len(pending) > 0 {
		var sid string
		if err := tx.QueryRow(r.Context(),
			`INSERT INTO conflict_sessions(note_id, user_id, device_id, base_rev)
			 VALUES($1,$2,$3,$4) RETURNING id`,
			noteID, c.UserID, c.DeviceID, req.LastServerRev).Scan(&sid); err != nil {
			writeErr(w, http.StatusInternalServerError, "conflict_session_create", err.Error())
			return
		}
		for _, pc := range pending {
			if _, err := tx.Exec(r.Context(),
				`INSERT INTO conflict_items(session_id, object_id, local_data, server_data)
				 VALUES($1,$2,$3,$4)`,
				sid, pc.objectID, []byte(pc.localData), []byte(pc.serverData)); err != nil {
				writeErr(w, http.StatusInternalServerError, "conflict_item_create", err.Error())
				return
			}
		}
		resp.ConflictSessionID = sid
	}

	// Create a commit record for accepted changes.
	if len(resp.Accepted) > 0 {
		// Find the latest commit ID for this note (parent link).
		var parentID *string
		var pid string
		if err := s.DB.QueryRow(r.Context(),
			`SELECT id FROM note_commits WHERE note_id=$1 ORDER BY created_at DESC LIMIT 1`,
			noteID).Scan(&pid); err == nil {
			parentID = &pid
		}
		if _, err := tx.Exec(r.Context(),
			`INSERT INTO note_commits(note_id, parent_id, user_id, device_id, message, rev_to)
			 VALUES($1,$2,$3,$4,$5,$6)`,
			noteID, parentID, c.UserID, c.DeviceID,
			autoMessage(req.Changes), resp.ServerRev); err != nil {
			writeErr(w, http.StatusInternalServerError, "commit_create", err.Error())
			return
		}
	}

	// Update sync cursor for this device.
	if c.DeviceID != "" {
		if _, err := tx.Exec(r.Context(),
			`INSERT INTO sync_cursors(user_id, note_id, device_id, last_rev, updated_at)
			 VALUES($1,$2,$3,$4, now())
			 ON CONFLICT(user_id, note_id, device_id) DO UPDATE
			   SET last_rev = GREATEST(sync_cursors.last_rev, EXCLUDED.last_rev),
			       updated_at = now()`,
			c.UserID, noteID, c.DeviceID, resp.ServerRev); err != nil {
			writeErr(w, http.StatusInternalServerError, "cursor_update", err.Error())
			return
		}
	}

	if err := tx.Commit(r.Context()); err != nil {
		writeErr(w, http.StatusInternalServerError, "tx_commit", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

// ───── Pull ───────────────────────────────────────────────────────────────

func (s *Service) Pull(w http.ResponseWriter, r *http.Request) {
	c, _ := auth.ClaimsFromContext(r.Context())
	noteID := chi.URLParam(r, "noteId")
	since := int64(0)
	if v := r.URL.Query().Get("since"); v != "" {
		if n, err := parseInt64(v); err == nil {
			since = n
		}
	}

	if !ownsNote(r.Context(), s.DB, c.UserID, noteID) {
		writeErr(w, http.StatusForbidden, "not_owner", "")
		return
	}

	resp := pullResp{Cursor: since}

	if since == 0 {
		var nm noteMeta
		var spec []byte
		err := s.DB.QueryRow(r.Context(),
			`SELECT id, title, scroll_axis, input_draw_mode, default_page_spec, rev, updated_at
			 FROM notes WHERE id=$1`, noteID).
			Scan(&nm.ID, &nm.Title, &nm.ScrollAxis, &nm.InputDrawMode, &spec, &nm.Rev, &nm.UpdatedAt)
		if err == nil {
			nm.DefaultPageSpec = json.RawMessage(spec)
			resp.Note = &nm
		}

		rows, err := s.DB.Query(r.Context(),
			`SELECT id, note_id, idx, spec, rev, updated_at FROM pages WHERE note_id=$1`, noteID)
		if err == nil {
			defer rows.Close()
			for rows.Next() {
				var p pageMeta
				var ps []byte
				if err := rows.Scan(&p.ID, &p.NoteID, &p.Index, &ps, &p.Rev, &p.UpdatedAt); err == nil {
					p.Spec = json.RawMessage(ps)
					resp.Pages = append(resp.Pages, p)
				}
			}
		}

		lrows, err := s.DB.Query(r.Context(),
			`SELECT id, page_id, z, name, visible, locked, opacity, rev, updated_at
			 FROM layers WHERE page_id IN (SELECT id FROM pages WHERE note_id=$1)`, noteID)
		if err == nil {
			defer lrows.Close()
			for lrows.Next() {
				var l layerMeta
				if err := lrows.Scan(&l.ID, &l.PageID, &l.Z, &l.Name, &l.Visible,
					&l.Locked, &l.Opacity, &l.Rev, &l.UpdatedAt); err == nil {
					resp.Layers = append(resp.Layers, l)
				}
			}
		}
	}

	rows, err := s.DB.Query(r.Context(),
		`SELECT id, page_id, layer_id, kind, data,
			COALESCE(bbox_minx, 'NaN'::float8),
			COALESCE(bbox_miny, 'NaN'::float8),
			COALESCE(bbox_maxx, 'NaN'::float8),
			COALESCE(bbox_maxy, 'NaN'::float8),
			rev, deleted, updated_at
		 FROM page_objects
		 WHERE page_id IN (SELECT id FROM pages WHERE note_id=$1)
		   AND rev > $2
		 ORDER BY rev ASC LIMIT 500`,
		noteID, since)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "objects_query", err.Error())
		return
	}
	defer rows.Close()
	for rows.Next() {
		var o objectChange
		var data []byte
		var minx, miny, maxx, maxy float64
		if err := rows.Scan(&o.ID, &o.PageID, &o.LayerID, &o.Kind, &data,
			&minx, &miny, &maxx, &maxy, &o.Rev, &o.Deleted, &o.UpdatedAt); err != nil {
			continue
		}
		o.Data = json.RawMessage(data)
		bbox := [4]float64{minx, miny, maxx, maxy}
		o.Bbox = &bbox
		resp.Changes = append(resp.Changes, o)
		if o.Rev > resp.Cursor {
			resp.Cursor = o.Rev
		}
	}
	resp.More = len(resp.Changes) >= 500

	writeJSON(w, http.StatusOK, resp)
}

// ───── History ────────────────────────────────────────────────────────────

// History returns the list of commits for a note (newest first, up to 100).
func (s *Service) History(w http.ResponseWriter, r *http.Request) {
	c, _ := auth.ClaimsFromContext(r.Context())
	noteID := chi.URLParam(r, "noteId")

	if !ownsNote(r.Context(), s.DB, c.UserID, noteID) {
		writeErr(w, http.StatusForbidden, "not_owner", "")
		return
	}

	rows, err := s.DB.Query(r.Context(),
		`SELECT id, parent_id, message, device_id, rev_to, created_at
		 FROM note_commits WHERE note_id=$1 ORDER BY created_at DESC LIMIT 100`, noteID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "query", err.Error())
		return
	}
	defer rows.Close()

	entries := []historyEntry{}
	for rows.Next() {
		var e historyEntry
		var parentID *string
		if err := rows.Scan(&e.ID, &parentID, &e.Message, &e.DeviceID, &e.RevTo, &e.CreatedAt); err == nil {
			if parentID != nil {
				e.ParentID = *parentID
			}
			entries = append(entries, e)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"commits": entries})
}

// HistorySnapshot returns the objects present at the time of a given commit.
// Objects are returned with their current data; only presence (rev <= revTo) is
// guaranteed, not the exact historical data values.
func (s *Service) HistorySnapshot(w http.ResponseWriter, r *http.Request) {
	c, _ := auth.ClaimsFromContext(r.Context())
	noteID := chi.URLParam(r, "noteId")
	commitID := chi.URLParam(r, "commitId")

	if !ownsNote(r.Context(), s.DB, c.UserID, noteID) {
		writeErr(w, http.StatusForbidden, "not_owner", "")
		return
	}

	var revTo int64
	var entry historyEntry
	var parentID *string
	err := s.DB.QueryRow(r.Context(),
		`SELECT id, parent_id, message, device_id, rev_to, created_at
		 FROM note_commits WHERE id=$1 AND note_id=$2`, commitID, noteID).
		Scan(&entry.ID, &parentID, &entry.Message, &entry.DeviceID, &revTo, &entry.CreatedAt)
	if err != nil {
		writeErr(w, http.StatusNotFound, "commit_not_found", "")
		return
	}
	entry.RevTo = revTo
	if parentID != nil {
		entry.ParentID = *parentID
	}

	rows, err := s.DB.Query(r.Context(),
		`SELECT id, page_id, layer_id, kind, data,
			COALESCE(bbox_minx, 'NaN'::float8),
			COALESCE(bbox_miny, 'NaN'::float8),
			COALESCE(bbox_maxx, 'NaN'::float8),
			COALESCE(bbox_maxy, 'NaN'::float8),
			rev, deleted, updated_at
		 FROM page_objects
		 WHERE page_id IN (SELECT id FROM pages WHERE note_id=$1)
		   AND rev <= $2 AND deleted = false
		 ORDER BY rev ASC`,
		noteID, revTo)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "snapshot_query", err.Error())
		return
	}
	defer rows.Close()

	objects := []objectChange{}
	for rows.Next() {
		var o objectChange
		var data []byte
		var minx, miny, maxx, maxy float64
		if err := rows.Scan(&o.ID, &o.PageID, &o.LayerID, &o.Kind, &data,
			&minx, &miny, &maxx, &maxy, &o.Rev, &o.Deleted, &o.UpdatedAt); err != nil {
			continue
		}
		o.Data = json.RawMessage(data)
		bbox := [4]float64{minx, miny, maxx, maxy}
		o.Bbox = &bbox
		objects = append(objects, o)
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"commit":  entry,
		"objects": objects,
	})
}

// HistoryRestore re-applies a historical snapshot as a new push.
// Objects that existed at commitId are written with fresh revisions;
// objects that currently exist but were not in the snapshot are tombstoned.
func (s *Service) HistoryRestore(w http.ResponseWriter, r *http.Request) {
	c, _ := auth.ClaimsFromContext(r.Context())
	noteID := chi.URLParam(r, "noteId")
	commitID := chi.URLParam(r, "commitId")

	if !ownsNote(r.Context(), s.DB, c.UserID, noteID) {
		writeErr(w, http.StatusForbidden, "not_owner", "")
		return
	}

	var revTo int64
	err := s.DB.QueryRow(r.Context(),
		`SELECT rev_to FROM note_commits WHERE id=$1 AND note_id=$2`, commitID, noteID).Scan(&revTo)
	if err != nil {
		writeErr(w, http.StatusNotFound, "commit_not_found", "")
		return
	}

	tx, err := s.DB.BeginTx(r.Context(), pgx.TxOptions{})
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "tx_begin", err.Error())
		return
	}
	defer tx.Rollback(r.Context())

	// Collect snapshot objects (rev <= revTo, alive at that time).
	type snapshotRow struct {
		id      string
		pageID  string
		layerID string
		kind    string
		data    []byte
		bboxMX  *float64
		bboxMY  *float64
		bboxXX  *float64
		bboxXY  *float64
	}
	snapRows, err := tx.Query(r.Context(),
		`SELECT id, page_id, layer_id, kind, data,
			bbox_minx, bbox_miny, bbox_maxx, bbox_maxy
		 FROM page_objects
		 WHERE page_id IN (SELECT id FROM pages WHERE note_id=$1)
		   AND rev <= $2 AND deleted = false`,
		noteID, revTo)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "snapshot_query", err.Error())
		return
	}

	var snapshots []snapshotRow
	snapIDs := map[string]struct{}{}
	for snapRows.Next() {
		var sr snapshotRow
		if err := snapRows.Scan(&sr.id, &sr.pageID, &sr.layerID, &sr.kind, &sr.data,
			&sr.bboxMX, &sr.bboxMY, &sr.bboxXX, &sr.bboxXY); err == nil {
			snapshots = append(snapshots, sr)
			snapIDs[sr.id] = struct{}{}
		}
	}
	snapRows.Close()

	// Collect current live objects not in the snapshot (to tombstone).
	liveRows, err := tx.Query(r.Context(),
		`SELECT id FROM page_objects
		 WHERE page_id IN (SELECT id FROM pages WHERE note_id=$1)
		   AND deleted = false`,
		noteID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "live_query", err.Error())
		return
	}
	var toDelete []string
	for liveRows.Next() {
		var id string
		if err := liveRows.Scan(&id); err == nil {
			if _, inSnap := snapIDs[id]; !inSnap {
				toDelete = append(toDelete, id)
			}
		}
	}
	liveRows.Close()

	now := time.Now().UTC()
	var maxRev int64

	// Tombstone objects not in snapshot.
	for _, id := range toDelete {
		var newRev int64
		if err := tx.QueryRow(r.Context(),
			`SELECT COALESCE(MAX(rev),0)+1 FROM page_objects`).Scan(&newRev); err != nil {
			writeErr(w, http.StatusInternalServerError, "rev_alloc", err.Error())
			return
		}
		if _, err := tx.Exec(r.Context(),
			`UPDATE page_objects SET deleted=true, rev=$1, updated_at=$2 WHERE id=$3`,
			newRev, now, id); err != nil {
			writeErr(w, http.StatusInternalServerError, "tombstone", err.Error())
			return
		}
		if newRev > maxRev {
			maxRev = newRev
		}
	}

	// Re-apply snapshot objects with fresh revisions.
	for _, sr := range snapshots {
		var newRev int64
		if err := tx.QueryRow(r.Context(),
			`SELECT COALESCE(MAX(rev),0)+1 FROM page_objects`).Scan(&newRev); err != nil {
			writeErr(w, http.StatusInternalServerError, "rev_alloc", err.Error())
			return
		}
		if _, err := tx.Exec(r.Context(),
			`UPDATE page_objects SET rev=$1, updated_at=$2, deleted=false WHERE id=$3`,
			newRev, now, sr.id); err != nil {
			writeErr(w, http.StatusInternalServerError, "restore_apply", err.Error())
			return
		}
		if newRev > maxRev {
			maxRev = newRev
		}
	}

	// Create a new commit pointing to this restore.
	var parentID *string
	var pid string
	if err := s.DB.QueryRow(r.Context(),
		`SELECT id FROM note_commits WHERE note_id=$1 ORDER BY created_at DESC LIMIT 1`,
		noteID).Scan(&pid); err == nil {
		parentID = &pid
	}
	if _, err := tx.Exec(r.Context(),
		`INSERT INTO note_commits(note_id, parent_id, user_id, device_id, message, rev_to)
		 VALUES($1,$2,$3,$4,$5,$6)`,
		noteID, parentID, c.UserID, c.DeviceID,
		fmt.Sprintf("Restored to commit %s", commitID[:8]), maxRev); err != nil {
		writeErr(w, http.StatusInternalServerError, "commit_create", err.Error())
		return
	}

	if err := tx.Commit(r.Context()); err != nil {
		writeErr(w, http.StatusInternalServerError, "tx_commit", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"serverRev": maxRev})
}

// ───── Conflicts ──────────────────────────────────────────────────────────

// GetConflict returns a pending conflict session with its items.
func (s *Service) GetConflict(w http.ResponseWriter, r *http.Request) {
	c, _ := auth.ClaimsFromContext(r.Context())
	noteID := chi.URLParam(r, "noteId")
	sid := chi.URLParam(r, "sid")

	var detail conflictDetail
	err := s.DB.QueryRow(r.Context(),
		`SELECT id, note_id, base_rev, status, created_at
		 FROM conflict_sessions
		 WHERE id=$1 AND note_id=$2 AND user_id=$3`,
		sid, noteID, c.UserID).
		Scan(&detail.ID, &detail.NoteID, &detail.BaseRev, &detail.Status, &detail.CreatedAt)
	if err != nil {
		writeErr(w, http.StatusNotFound, "session_not_found", "")
		return
	}

	rows, err := s.DB.Query(r.Context(),
		`SELECT id, object_id, local_data, server_data,
			COALESCE(resolution, '')
		 FROM conflict_items WHERE session_id=$1`, sid)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "items_query", err.Error())
		return
	}
	defer rows.Close()
	for rows.Next() {
		var item conflictItemDetail
		var ld, sd []byte
		if err := rows.Scan(&item.ID, &item.ObjectID, &ld, &sd, &item.Resolution); err == nil {
			item.LocalData = json.RawMessage(ld)
			item.ServerData = json.RawMessage(sd)
			detail.Items = append(detail.Items, item)
		}
	}
	if detail.Items == nil {
		detail.Items = []conflictItemDetail{}
	}
	writeJSON(w, http.StatusOK, detail)
}

// ResolveConflict applies resolutions for each item in a conflict session.
// Each item resolution is: "local" (apply client version), "server" (keep server),
// or "deleted" (tombstone the object). After all items are resolved the session
// is marked resolved and a new commit is created for any written objects.
func (s *Service) ResolveConflict(w http.ResponseWriter, r *http.Request) {
	c, _ := auth.ClaimsFromContext(r.Context())
	noteID := chi.URLParam(r, "noteId")
	sid := chi.URLParam(r, "sid")

	var req resolveReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid_body", err.Error())
		return
	}

	// Verify session ownership.
	var baseRev int64
	var status string
	err := s.DB.QueryRow(r.Context(),
		`SELECT base_rev, status FROM conflict_sessions
		 WHERE id=$1 AND note_id=$2 AND user_id=$3`,
		sid, noteID, c.UserID).Scan(&baseRev, &status)
	if err != nil {
		writeErr(w, http.StatusNotFound, "session_not_found", "")
		return
	}
	if status != "pending" {
		writeErr(w, http.StatusConflict, "session_not_pending", "session already "+status)
		return
	}

	tx, err := s.DB.BeginTx(r.Context(), pgx.TxOptions{})
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "tx_begin", err.Error())
		return
	}
	defer tx.Rollback(r.Context())

	now := time.Now().UTC()
	var maxRev int64
	appliedCount := 0

	for _, res := range req.Resolutions {
		if res.Resolution != "local" && res.Resolution != "server" && res.Resolution != "deleted" {
			writeErr(w, http.StatusBadRequest, "invalid_resolution",
				fmt.Sprintf("item %s: unknown resolution %q", res.ItemID, res.Resolution))
			return
		}

		// Load item.
		var objectID string
		var localData, serverData []byte
		err := tx.QueryRow(r.Context(),
			`SELECT object_id, local_data, server_data
			 FROM conflict_items WHERE id=$1 AND session_id=$2`,
			res.ItemID, sid).Scan(&objectID, &localData, &serverData)
		if err != nil {
			writeErr(w, http.StatusNotFound, "item_not_found", res.ItemID)
			return
		}

		switch res.Resolution {
		case "server":
			// Server version already applied; nothing to write.
		case "deleted":
			var newRev int64
			if err := tx.QueryRow(r.Context(),
				`SELECT COALESCE(MAX(rev),0)+1 FROM page_objects`).Scan(&newRev); err != nil {
				writeErr(w, http.StatusInternalServerError, "rev_alloc", err.Error())
				return
			}
			if _, err := tx.Exec(r.Context(),
				`UPDATE page_objects SET deleted=true, rev=$1, updated_at=$2 WHERE id=$3`,
				newRev, now, objectID); err != nil {
				writeErr(w, http.StatusInternalServerError, "delete_apply", err.Error())
				return
			}
			if newRev > maxRev {
				maxRev = newRev
			}
			appliedCount++
		case "local":
			var newRev int64
			if err := tx.QueryRow(r.Context(),
				`SELECT COALESCE(MAX(rev),0)+1 FROM page_objects`).Scan(&newRev); err != nil {
				writeErr(w, http.StatusInternalServerError, "rev_alloc", err.Error())
				return
			}
			if _, err := tx.Exec(r.Context(),
				`UPDATE page_objects SET data=$1, rev=$2, updated_at=$3, deleted=false
				 WHERE id=$4`,
				localData, newRev, now, objectID); err != nil {
				writeErr(w, http.StatusInternalServerError, "local_apply", err.Error())
				return
			}
			if newRev > maxRev {
				maxRev = newRev
			}
			appliedCount++
		}

		// Mark item resolved.
		if _, err := tx.Exec(r.Context(),
			`UPDATE conflict_items SET resolution=$1, resolved_at=$2 WHERE id=$3`,
			res.Resolution, now, res.ItemID); err != nil {
			writeErr(w, http.StatusInternalServerError, "item_update", err.Error())
			return
		}
	}

	// Mark session resolved.
	if _, err := tx.Exec(r.Context(),
		`UPDATE conflict_sessions SET status='resolved', resolved_at=$1 WHERE id=$2`,
		now, sid); err != nil {
		writeErr(w, http.StatusInternalServerError, "session_update", err.Error())
		return
	}

	// Create commit if any objects were written.
	if appliedCount > 0 {
		var parentID *string
		var pid string
		if err := s.DB.QueryRow(r.Context(),
			`SELECT id FROM note_commits WHERE note_id=$1 ORDER BY created_at DESC LIMIT 1`,
			noteID).Scan(&pid); err == nil {
			parentID = &pid
		}
		if _, err := tx.Exec(r.Context(),
			`INSERT INTO note_commits(note_id, parent_id, user_id, device_id, message, rev_to)
			 VALUES($1,$2,$3,$4,$5,$6)`,
			noteID, parentID, c.UserID, c.DeviceID,
			fmt.Sprintf("Resolved %d conflict(s)", appliedCount), maxRev); err != nil {
			writeErr(w, http.StatusInternalServerError, "commit_create", err.Error())
			return
		}
	}

	if err := tx.Commit(r.Context()); err != nil {
		writeErr(w, http.StatusInternalServerError, "tx_commit", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"serverRev": maxRev})
}

// ───── Helpers ────────────────────────────────────────────────────────────

func upsertOwnedNote(ctx context.Context, tx pgx.Tx, userID, noteID string, meta *noteMeta) error {
	var owner string
	err := tx.QueryRow(ctx,
		`SELECT owner_id FROM notes WHERE id=$1`, noteID).Scan(&owner)
	if errors.Is(err, pgx.ErrNoRows) {
		if meta == nil {
			meta = &noteMeta{
				ID: noteID, Title: "Untitled", ScrollAxis: "vertical",
				InputDrawMode: "any",
				DefaultPageSpec: json.RawMessage(`{"widthPt":595.276,"heightPt":841.89,"kind":"a4","background":{"kind":"blank"}}`),
				Rev: 0, UpdatedAt: time.Now().UTC(),
			}
		}
		_, err := tx.Exec(ctx,
			`INSERT INTO notes(id, owner_id, title, scroll_axis, input_draw_mode,
			   default_page_spec, rev, created_at, updated_at)
			 VALUES($1,$2,$3,$4,$5,$6,$7, now(), $8)`,
			meta.ID, userID, meta.Title, meta.ScrollAxis, meta.InputDrawMode,
			[]byte(meta.DefaultPageSpec), meta.Rev, meta.UpdatedAt)
		return err
	}
	if err != nil {
		return err
	}
	if owner != userID {
		return errors.New("note belongs to a different user")
	}
	if meta != nil {
		_, _ = tx.Exec(ctx,
			`UPDATE notes SET title=$1, scroll_axis=$2, input_draw_mode=$3,
			   default_page_spec=$4, rev=$5, updated_at=$6
			 WHERE id=$7 AND updated_at <= $6`,
			meta.Title, meta.ScrollAxis, meta.InputDrawMode,
			[]byte(meta.DefaultPageSpec), meta.Rev, meta.UpdatedAt, meta.ID)
	}
	return nil
}

func ownsNote(ctx context.Context, db *pgxpool.Pool, userID, noteID string) bool {
	var n int
	if err := db.QueryRow(ctx,
		`SELECT 1 FROM notes WHERE id=$1 AND owner_id=$2`, noteID, userID).Scan(&n); err != nil {
		return false
	}
	return true
}

func autoMessage(changes []objectChange) string {
	adds, dels := 0, 0
	for _, c := range changes {
		if c.Deleted {
			dels++
		} else {
			adds++
		}
	}
	switch {
	case dels == 0:
		return fmt.Sprintf("Added %d object(s)", adds)
	case adds == 0:
		return fmt.Sprintf("Deleted %d object(s)", dels)
	default:
		return fmt.Sprintf("Added %d, deleted %d object(s)", adds, dels)
	}
}

func nullableTime(t time.Time) any {
	if t.IsZero() {
		return time.Now().UTC()
	}
	return t
}

func parseInt64(s string) (int64, error) {
	var v int64
	for _, c := range s {
		if c < '0' || c > '9' {
			return 0, errors.New("not int")
		}
		v = v*10 + int64(c-'0')
	}
	return v, nil
}

func writeJSON(w http.ResponseWriter, code int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(body)
}

func writeErr(w http.ResponseWriter, status int, code, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"error": map[string]any{"code": code, "message": msg},
	})
}
