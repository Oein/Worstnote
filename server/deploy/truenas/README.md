# Deploy Notee on TrueNAS Scale

This directory contains a turnkey Docker Compose stack for running the Notee
backend on a TrueNAS Scale box.

> **Compatibility**
> - **TrueNAS Scale 24.10 "Electric Eel" or newer** — uses native Docker
>   Compose for Custom Apps. **This is the supported path.**
> - **TrueNAS Scale 23.x (Bluefin/Cobia)** — uses K3s. The Compose file
>   here will not work directly; either upgrade, or convert to a Helm chart
>   (PRs welcome).

## What gets deployed

| Service | Purpose | Persistent data |
|---|---|---|
| `postgres` | Notes/users/sync metadata (Postgres 16) | `${DATA_DIR}/postgres` |
| `minio` | S3-compatible store for PDF/image assets | `${DATA_DIR}/minio` |
| `minio-init` | One-shot: creates the assets bucket | — |
| `notee-api` | Go HTTP API (this repo's `server/`) | — |
| `migrate` | One-shot: runs goose migrations | — |

## One-time setup

1. **Create datasets** on your pool. From the TrueNAS UI:
   `Datasets → Add Dataset → tank/apps/notee` then add children
   `postgres` and `minio` (Generic preset is fine; encryption optional).

2. **Copy these files** to the NAS, e.g. via SMB or `scp`:

   ```
   /mnt/tank/apps/notee/
       docker-compose.yml         (this directory's file)
       .env                       (copy from .env.example, fill in)
   ```

3. **Generate strong secrets** in `.env`:

   ```sh
   openssl rand -base64 48      # → JWT_SECRET
   openssl rand -base64 24      # → POSTGRES_PASSWORD
   openssl rand -base64 24      # → MINIO_ROOT_PASSWORD
   ```

4. **Bring up the stack**. Two options:

   - **TrueNAS UI**: `Apps → Discover Apps → Custom App`, paste the contents
     of `docker-compose.yml`. Set the working directory so it can read your
     `.env`. Confirm.
   - **Shell** (privileged, requires `apps` to be initialized):
     ```sh
     cd /mnt/tank/apps/notee
     docker compose up -d
     ```

5. **Run the schema migration once**:

   ```sh
   cd /mnt/tank/apps/notee
   docker compose --profile migrate run --rm migrate
   ```

   You should see `goose: no migrations to run` on subsequent boots until
   you bump `migrations/`.

6. **(Recommended) Front with TLS via Caddy**. See `caddy/Caddyfile.example`.
   The Notee API itself does **not** terminate TLS.

## Backup strategy

- The two datasets you created (`postgres`, `minio`) hold *all* persistent
  state. Snapshot them on the same TrueNAS schedule you already use, and
  the system is fully recoverable.
- Replicate to a remote TrueNAS for off-site backup if you have one.

## Updating

```sh
cd /mnt/tank/apps/notee
docker compose pull
docker compose --profile migrate run --rm migrate
docker compose up -d
```

The `notee-api` container is stateless; rolling it is safe at any time
once migrations are caught up.

## Sizing

Typical home-server load (≤ 20 active users):

| Resource | Suggested |
|---|---|
| CPU | 1 vCPU (2 if you also run TLS termination + heavy backups in the same box) |
| RAM | 2 GB total (1 for Postgres, 256 MB for the API, the rest is OS + cache) |
| Disk | Depends on PDF imports. Plan `users × avg_pdfs × avg_pdf_size`. The DB itself is tiny (vector strokes are small). |

## Health checks

```sh
curl -s http://NAS-IP:8080/v1/health
# → {"status":"ok","now":"2026-..."}
```

## Troubleshooting

- **`migrate` container errors `connect: connection refused`**
  Postgres hadn't reached `healthy`. Check `docker compose ps` and
  `docker compose logs postgres`.
- **Asset uploads time out from the client**
  The client uploads directly to MinIO via presigned URL, so MinIO must
  be reachable from clients — not just from the API container. Either
  expose port 9000 on the NAS LAN (default) and use it in the API's
  `S3_PUBLIC_ENDPOINT` (added in P9), or proxy `/s3/*` through Caddy.
- **`bind: address already in use`**
  Another app on the NAS is using 8080/9000/9001. Set `API_PORT`,
  `MINIO_S3_PORT`, `MINIO_CONSOLE_PORT` in `.env`.
