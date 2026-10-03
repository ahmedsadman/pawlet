# Pawlet LLM Proxy Server

Attestation-gated proxy for bank SMS classification. Holds an OpenRouter API key and admits only Android installs that pass Play Integrity attestation. Sideloaded builds that cannot attest instead fetch a prompt bundle and call OpenRouter directly with their own key.

Design: [docs/superpowers/specs/2026-10-01-llm-proxy-attestation-design.md](../docs/superpowers/specs/2026-10-01-llm-proxy-attestation-design.md)

## Endpoints

| Method | Path                 | Auth      | Purpose                                                     |
|--------|----------------------|-----------|-------------------------------------------------------------|
| GET    | `/healthz`           | None      | Liveness check (200 OK with empty body)                    |
| GET    | `/v1/challenge`      | None      | Issue a single-use challenge for integrity verification    |
| POST   | `/v1/session`        | Challenge | Consume challenge + integrity token, return session JWT    |
| POST   | `/v1/classify`       | JWT       | Classify bank SMS via OpenRouter (attested installs only)  |
| GET    | `/v1/prompt-bundle`  | None      | Fetch prompt templates for client-side classification      |

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

The SQLite database holds only anonymous install hashes and usage counters. No message content, device identifiers, or personally identifiable information is persisted.

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
    reverse_proxy pawlet:8080
}
```

The service does NOT publish ports to the host — Caddy reaches it over the shared Docker network (`caddy_net` by default in docker-compose.yml; update to match your actual network name from `docker network inspect`).

**Prerequisites:**
- Docker network for reverse proxy (create with `docker network create caddy_net` if needed)
- `./service-account.json` in the server directory
- `.env` file populated from `.env.example`

## Backups

The SQLite file at `/data/pawlet.db` holds only:
- Anonymous install hashes (SHA-256 of package + signing cert)
- Daily and burst usage counters
- Challenge nonces (expire after 5 minutes)

A nightly volume copy suffices:
```bash
docker run --rm -v pawlet-data:/source -v /backup:/dest alpine \
  tar czf /dest/pawlet-data-$(date +%F).tar.gz -C /source .
```

Retention: keep 7 days of backups. The database resets quota counters daily, so historical data beyond a week has no operational value.
