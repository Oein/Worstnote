# Sync Protocol (delta · LWW)

## Goals
- **Local-first**: every edit lands in SQLite immediately, then queues for the server.
- **Cheap recovery**: append-only stroke model + tombstones means lost packets rarely cost data.
- **Replaceable**: the wire shape is small enough that we can swap LWW for OT/CRDT later without changing client UX.

## Units
The sync unit is a row in `page_objects`. `notes`, `pages`, and `layers` carry their own `rev` for metadata changes (title, scroll axis, page spec, layer name/order/lock/opacity).

## Client-side flow
1. Apply edit locally → drift transaction:
   - Bump local `rev = max(localRev) + 1`.
   - Set `updatedAt = wall clock UTC`.
   - Set `deviceId` (stable per install).
   - Insert/Upsert into `outbox` table.
2. When online and authed, drain outbox:
   - `POST /v1/sync/{noteId}/push` with up to N changes.
   - On 200, reconcile: replace local `rev` with `serverRev` for accepted rows, apply server version for any conflict, requeue retries.
3. Periodic / on-focus pull:
   - `GET /v1/sync/{noteId}/pull?since=<cursor>` → applies deltas in tx, advances cursor.

## Wire format

### Push request
```json
{
  "lastServerRev": 1024,
  "changes": [
    {
      "id": "uuid", "kind": "stroke",
      "data": { "...PageObject..." },
      "rev": 73, "deleted": false,
      "updatedAt": "2026-04-26T03:11:00.123Z",
      "deviceId": "macbook-air-1"
    }
  ]
}
```

### Push response
```json
{
  "serverRev": 1042,
  "accepted": [{ "id": "uuid", "serverRev": 1041 }],
  "conflicts": [
    { "id": "uuid", "winner": "server",
      "serverVersion": { "...PageObject with serverRev..." } }
  ]
}
```

### Pull response
```json
{
  "cursor": "1042",
  "changes": [ { "id": "uuid", "kind": "stroke", "data": {...}, "rev": 1041, "deleted": false } ],
  "more": false
}
```

## Conflict resolution (LWW)
1. If `client.updatedAt > server.updatedAt` → client wins; advance `serverRev`.
2. Else server version is returned in `conflicts`; client must overwrite local copy.
3. Tie-break on equal `updatedAt`: lexicographically larger `deviceId` wins (deterministic across devices).

> Strokes are append-only; conflicts are vanishingly rare. They only show up when the same object is mutated (text edit, shape resize, layer move, tape opacity change).

## Page checksum (drift detection)
- Periodically (e.g. on note open and every 5 min while open):
  - Compute `sha256(sorted_join(active_object_ids, "\n"))` per page.
  - Send a small `GET /v1/sync/{noteId}/checksum?pageIds=...` and compare.
  - On mismatch, force a page-scoped pull from `since=0` for affected pages.

## Asset upload
1. `POST /v1/assets:initiate` with `{ sha256, sizeBytes, mime }`.
2. Server returns `{ assetId, putUrl, objectKey }` (presigned, ~15 min TTL); deduplicates on `(owner, sha256)`.
3. Client `PUT` directly to S3/MinIO.
4. `POST /v1/assets:complete { assetId }` — server `HEAD`s the object, marks `completed=true`, then assets can be referenced from `PageBackground.kind in ('pdf','image')`.
