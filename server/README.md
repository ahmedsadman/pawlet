# Pawlet LLM Proxy Server

Attestation-gated proxy for bank SMS classification. Holds an OpenRouter API key and admits only Android installs that pass Play Integrity attestation. Sideloaded builds that cannot attest instead fetch a prompt bundle and call OpenRouter directly with their own key.

## Endpoints

| Method | Path                 | Auth      | Purpose                                                     |
|--------|----------------------|-----------|-------------------------------------------------------------|
| GET    | `/healthz`           | None      | 200 `ok` only if SQLite answers; 503 `database_unavailable` otherwise |
| GET    | `/v1/challenge`      | None      | Issue a single-use challenge for integrity verification    |
| POST   | `/v1/session`        | Challenge | Consume challenge + integrity token, return session JWT    |
| POST   | `/v1/classify`       | JWT       | Classify bank SMS via OpenRouter (attested installs only)  |
| GET    | `/v1/prompt-bundle`  | None      | Fetch prompt templates for client-side classification      |

## Admin dashboard

A separate binary, `pawlet-admin`, serves the owner-only dashboard over the same database.
See [docs/admin.md](docs/admin.md).

## Configuration

All configuration is via environment variables. See [.env.example](./.env.example) for the full list with defaults.

**CRITICAL:** `CERT_SHA256_DIGESTS` must contain the **Play app-signing** certificate digest from the Play Console, NOT the upload certificate. Using the upload digest will reject every genuine install. This is the single easiest thing to get wrong.

Required variables:
- `OPENROUTER_API_KEY`
- `JWT_SECRET` (minimum 32 bytes)
- `GOOGLE_SERVICE_ACCOUNT_JSON` (path to service account JSON file)
- `CERT_SHA256_DIGESTS` (comma-separated SHA-256 digests)

## Privacy

Message content is never written to disk and never logged. The logging middleware has no access to request bodies by construction. Log lines carry only:
- 8-character install hash prefix (anonymous)
- Timestamp
- HTTP status
- Latency
- Token counts (for `/v1/classify`)

The SQLite database holds anonymous install hashes, usage counters, a summary of each install's latest Play Integrity verdict (app version, device tier, licensing, Android SDK level), the days each install attested, and daily aggregate outcome counters. No message content, device identifiers, or personally identifiable information is persisted. See [docs/metrics.md](docs/metrics.md).

## Development

**Running tests:**
```bash
go test ./... -race -count=1
```

**Building:**
```bash
go build ./cmd/pawletd
```

**Running locally:**
```bash
# Create .env from .env.example and populate required variables
cp .env.example .env
# Edit .env with real values

# Place your Google service account JSON at ./service-account.json
# or update GOOGLE_SERVICE_ACCOUNT_JSON in .env

./pawletd
```

**Note:** Debug Android builds use `applicationIdSuffix = ".debug"` so they will never pass attestation. Test with release-signed APKs or use `DEV_SHARED_SECRET` for local bypass (development mode only).

## Deployment

**Build and start:**
```bash
docker compose up -d --build
```

**Caddy configuration:**

Add this site block to your Caddyfile (adjust hostname as needed):
```
pawlet.muhib.me {
    reverse_proxy localhost:8091
}
```

This assumes Caddy runs with `network_mode: host`, which is why the proxy target
is `localhost` rather than a container name. The compose file publishes the
service on `127.0.0.1:8091` only, so Caddy can reach it while the port stays off
the public interface. Change the host-side port if 8091 is already taken.

**Client IP and `TRUSTED_PROXY_CIDR`:**

Caddy sets `X-Forwarded-For`, and the service only honours it when the immediate
peer is inside `TRUSTED_PROXY_CIDR`. With a loopback-published port, the
container sees the Docker bridge gateway (usually `172.17.0.1`) as the peer, so
the default `172.16.0.0/12` covers it. Tighten to `172.17.0.1/32` if you want to
stop other containers on the default bridge from being trusted.

Verify after deploying: trip the challenge rate limit and check the log line.

```bash
for i in $(seq 1 70); do curl -s -o /dev/null https://pawlet.muhib.me/v1/challenge; done
docker compose logs pawlet | grep "challenge rate limit"
```

The `ip` field must show the real client address. If it shows `172.17.0.1` or
another fixed value, `X-Forwarded-For` is not being trusted and every client
shares one rate-limit bucket.

**Prerequisites:**
- `./service-account.json` in the server directory
- `.env` file populated from `.env.example`
- `mkdir -p data` — the SQLite bind mount. The container runs as your host uid
  so the files stay writable; if your uid is not 1000, start with
  `PAWLET_UID=$(id -u) PAWLET_GID=$(id -g) docker compose up -d`

### Continuous deployment

Merges to `main` that touch `server/` run `.github/workflows/server-deploy.yml`:

1. **checks**: format, vet, lint and tests, the same checks pull requests run.
2. **build**: pushes `ghcr.io/ahmedsadman/pawlet-server:<commit sha>` and
   `:latest`.
3. **deploy**: SSHes in as `deploy`, runs `git pull` in `~/pawlet`, then pulls
   that commit's image and restarts the container.
4. **health check**: fails the run if `https://pawlet.muhib.me/healthz` does not
   answer within about 25 seconds. There is no automatic rollback.

To roll back by hand, every commit's image stays in GHCR:

```bash
cd ~/pawlet/server
IMAGE_TAG=<previous commit sha> docker compose up -d --no-build
```

One-time setup:
- Repository secrets `SERVER_IP` and `SSH_PRIVATE_KEY`, for the `deploy` user.
- The checkout at `/home/deploy/pawlet`, owned by `deploy`, which must be able
  to run Docker.
- If `deploy`'s uid is not 1000, put `PAWLET_UID` and `PAWLET_GID` in `.env`.
  Compose reads `.env` for variable substitution, and the deploy does not set
  them.
- After the first run, make the `pawlet-server` package **public** in GitHub.
  GHCR creates packages private, and the server pulls without logging in.

## Backups

The database is bind-mounted at `server/data/pawlet.db`, owned by your host
user, so no `sudo` or `docker cp` is needed to reach it. It holds only:
- Anonymous install hashes (SHA-256 of the random per-install ID), ban flags, and each
  install's latest verdict summary
- Daily usage counters, session days, and daily aggregate outcome counters
- The effective limits pawletd published at startup

Challenge nonces are **not** in the database — they live in memory with a
2-minute TTL and are deliberately lost on restart.

### Use sqlite3 `.backup`, not `cp`

The database runs in WAL mode, so recent writes sit in `pawlet.db-wal` until a
checkpoint. Copying `pawlet.db` on its own yields a file with **no tables**.
Copying all three files together is racy against a running service.

`.backup` uses SQLite's online backup API and is safe while the service runs:

```bash
sqlite3 server/data/pawlet.db ".backup /backup/pawlet-$(date +%F).db"
```

Verify before trusting it:

```bash
sqlite3 /backup/pawlet-$(date +%F).db "select count(*) from installs"
```

Retention: keep at least a week. The install table refills as clients
re-attest, but the history behind the stats — daily usage, session days and
outcome counters — exists nowhere else, so a backup is the only way to get it
back.
