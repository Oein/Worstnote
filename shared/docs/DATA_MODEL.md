# Data Model

The canonical schema is **`shared/proto/notee.schema.json`**. This document is the human-readable companion.

## Hierarchy

```
User
└── Note (scrollAxis: vertical|horizontal, defaultPageSpec)
    └── Page (spec: PageSpec — width/height/kind/background, may differ per page)
        └── Layer (z, visible, locked, opacity, name)
            └── PageObject  (Stroke | Shape | TextBox | Tape)
```

- A `Note` lives entirely on one user. The user picks a per-note **scroll axis** (vertical or horizontal) and a **default `PageSpec`** for new pages.
- A `Page` always carries its **own `PageSpec`** (size + background). PDF imports produce one Page per PDF page, each with its native size.
- A `Page` always has at least one `Layer` (named "Default"). Tape objects auto-route to a top "Tape" layer.
- All `PageObject` rows share a single `page_objects` table on the server (kind-discriminated JSONB) and a parallel `objects` table on the client (drift). This makes sync uniform.

## PageSpec
| Field | Type | Notes |
|------|------|-------|
| `widthPt` | number | 1pt = 1/72 inch. A4 = 595, Letter = 612, etc. |
| `heightPt` | number | |
| `kind` | enum | `a4` `letter` `b5` `square` `custom` `pdfImported` |
| `background` | union | `blank` `grid(spacingPt)` `ruled(spacingPt)` `dot(spacingPt)` `image(assetId)` `pdf(assetId, pageNo)` |

## Stroke points
`StrokePoint{ x, y, pressure, tiltX, tiltY, tMs }`
- `pressure` ∈ [0, 1] (0.5 if device has none).
- `tiltX/tiltY` in radians.
- `tMs` is relative milliseconds from the first point (used for timing-based effects, not for rendering position).

## Bounding box
Stored as `[minx, miny, maxx, maxy]` in page-pt coordinates. Recompute on every mutation; used for selection, viewport culling, and (server-side) range queries.

## Revisions
- Every row carries a monotonically increasing `rev` (per row family on client, per `page_objects` row on server).
- Server `rev` is allocated by the sync handler at write time.
- Tombstones (`deleted=true`) survive forever — they are how clients learn about deletes.

## Asset references
PDF/image backgrounds reference `assets.id`. The `object_key` lives in S3/MinIO and is **content-addressed** by SHA-256 (so two users uploading the same PDF dedupe by key but each gets their own `assets` row for ownership/cleanup).
