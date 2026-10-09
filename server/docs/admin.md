# Admin dashboard service

`pawlet-admin` is the owner-only dashboard. It reads the SQLite file pawletd writes, computes
every statistic on request, lets the owner ban and unban installs, and serves the dashboard UI
from files embedded at build time. It runs as its own process so a problem in the admin surface
cannot affect the classify API.

## Pieces

| Path                       | Role                                                                                        |
| -------------------------- | ------------------------------------------------------------------------------------------- |
| `cmd/pawlet-admin/main.go` | Binary: `serve` (default), `hash-password`, `dev-seed`                                      |
| `internal/admin/`          | Config, password check, login limiter, sessions, request guards, JSON handlers, embedded UI |
| `internal/stats/`          | Pure functions that turn database rows into every dashboard number                          |
| `internal/store/rows.go`   | Row loaders the admin reads                                                                 |
| `internal/devseed/`        | Fake history for local work                                                                 |

The admin never migrates the database: it opens it with `store.OpenExisting`, which refuses a
schema older than the binary needs. Start pawletd first after a schema change.

## Running locally

1. Get a database. Either point `DATABASE_PATH` at the one local pawletd uses, or create a
   fake one: `go run ./cmd/pawlet-admin dev-seed --db data/dev.db` (refuses a database that
   already has installs before touching it).
2. Generate a password hash: `go run ./cmd/pawlet-admin hash-password`, type the password,
   press Enter. The password is visible as you type (or pipe it in with
   `printf '%s\n' "$PW" | go run ./cmd/pawlet-admin hash-password`).
3. Run it:

   ```bash
   ADMIN_PASSWORD_HASH='<hash>' ADMIN_SESSION_SECRET="$(openssl rand -base64 48)" \
   ADMIN_ADDR=:8092 DATABASE_PATH=data/dev.db go run ./cmd/pawlet-admin
   ```

   Single-quote the hash: it contains `$`.

4. The API answers on `http://localhost:8092/api/...`. The UI is served once built — `npm run
build:embed` in `dashboard/` locally, automatically in the image.

Chrome and Firefox accept the session cookie's `Secure` flag on `http://localhost`, so login
works locally without TLS; other browsers may differ.

## Configuration

Read from the environment by `internal/admin/config.go`; template in `admin.env.example`.
The admin deliberately receives none of pawletd's secrets.

| Variable               | Required | Meaning                                                                                                                                                                                                            |
| ---------------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `ADMIN_PASSWORD_HASH`  | yes      | argon2id PHC string from `hash-password`; must be a canonical hash within bounds (memory 19456–1048576 KiB, time 1–10, threads 1–16, salt ≥ 8 bytes, key 16–64 bytes); `hash-password` always produces a valid one |
| `ADMIN_SESSION_SECRET` | yes      | at least 32 bytes; signs the session cookie; rotating it signs everyone out                                                                                                                                        |
| `ADMIN_ADDR`           | no       | listen address                                                                                                                                                                                                     |
| `DATABASE_PATH`        | no       | pawletd's SQLite file                                                                                                                                                                                              |
| `TRUSTED_PROXY_CIDR`   | no       | proxy network whose `X-Forwarded-For` is trusted                                                                                                                                                                   |

## Deploying

Image: `ghcr.io/ahmedsadman/pawlet-admin`, built by `.github/workflows/server-deploy.yml` from
`server/admin.Dockerfile` (build context = repo root). **After the first CI run**, make the package
public in GitHub, like `pawlet-server` — until then (or until the host logs in to ghcr), the admin
pull fails with a warning.

Compose service `pawlet-admin` in `server/docker-compose.yml`: loopback port `127.0.0.1:8092`, same
`./data` mount read-write, `env_file: admin.env` with `required: false` so pawletd still deploys
without it, `depends_on: pawlet`, `restart: unless-stopped`. The compose file's `env_file` long
syntax (`required: false`) needs Docker Compose 2.24 or newer — check `docker compose version`
before the first deploy; an older Compose fails to parse the file and the deploy stops before
pawletd is updated.

**Before the first deploy**, on the host:

1. Create `server/admin.env` from `admin.env.example`; get the hash from
   `docker run --rm -i ghcr.io/ahmedsadman/pawlet-admin hash-password` or `go run`.
   **Wrap the hash in single quotes** (`ADMIN_PASSWORD_HASH='$argon2id$…'`): Compose expands
   `$` in env files, so an unquoted hash is silently mangled and no password will match.
2. Add a DNS record for `admin.pawlet.muhib.me`.
3. Add a Caddy site block reverse-proxying to `localhost:8092`:

   ```
   admin.pawlet.muhib.me {
       reverse_proxy localhost:8092
   }
   ```

4. Reload Caddy.

Deploy order is automatic: pawletd migrates the schema; the admin restarts until the schema is new
enough. The admin sets HSTS itself — don't add it in Caddy.

Rotating `ADMIN_SESSION_SECRET` signs everyone out; changing the password means a new hash and a
container restart.

## Security

- **Login:** one password, checked with argon2id in constant time (`internal/admin/password.go`).
- **Session:** an HttpOnly, Secure, SameSite=Strict cookie (`__Host-pawlet_admin`) holding a JWT
  signed with `ADMIN_SESSION_SECRET` and subject `admin` (`internal/admin/sessions.go`). It cannot
  be confused with a pawletd session token, which uses a different secret and subject. Logout clears
  the cookie but does not revoke the token: a stolen cookie stays valid until it expires (7 days);
  rotating `ADMIN_SESSION_SECRET` revokes every session.
- **Brute force:** failed logins are limited per client address and across all addresses
  (`internal/admin/loginlimit.go`); a limited attempt is refused before any password work.
  Concurrent password checks are capped at 2; a login that finds both busy gets 429. The body is
  read before taking a slot. The client address is resolved through the trusted proxy the same way
  pawletd does (`internal/clientip/clientip.go`).
- **Cross-site requests:** every POST must send a JSON body (media type exactly `application/json`)
  and an `Origin` whose host matches the request Host and whose scheme is https — plain http is
  accepted only for loopback hosts (local development) (`internal/admin/middleware.go`), on top of
  SameSite=Strict.
- **Headers:** response headers include a same-origin Content-Security-Policy (with
  `object-src 'none'`), `frame-ancestors 'none'`, `X-Frame-Options: DENY`, nosniff, `no-referrer`,
  `Cross-Origin-Opener-Policy: same-origin`, and `Strict-Transport-Security` on every response,
  so HSTS should not also be added in Caddy.
- Failed logins are logged with the client address, never the submitted password.

## API

All `/api/*` routes return JSON; `/healthz` returns plain text. Days are UTC `YYYY-MM-DD`,
timestamps unix seconds. `range` is `7d`, `30d` (default), `90d` or `all`.

| Route                                                                           | Purpose                                                                                                                               |
| ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `GET /healthz`                                                                  | 200 when the database answers                                                                                                         |
| `POST /api/login`, `POST /api/logout`, `GET /api/me`                            | session                                                                                                                               |
| `GET /api/overview?range=`                                                      | headline numbers, daily calls/active/new installs, server info                                                                        |
| `GET /api/installs?sort=&order=&q=&status=&page=`                               | installs table (50 per page; `q` is a hash prefix; `status` is `all`, `active`, `dormant` or `banned`); an invalid `page` returns 400 |
| `GET /api/installs/{hash}`                                                      | one install with its daily history                                                                                                    |
| `POST /api/installs/{hash}/ban` `{"reason"}`, `POST /api/installs/{hash}/unban` | ban control; pawletd checks the flag on every request, so a ban applies to the install's next call                                    |
| `GET /api/engagement?range=&active=any\|classify`                               | active installs, stickiness, cohorts, calls distribution, dormant count                                                               |
| `GET /api/reliability?range=`                                                   | outcomes, success rate, latency percentiles, models, categories, tokens per call                                                      |
| `GET /api/fleet`                                                                | app version, device tier, licensing and SDK of recently active installs; version adoption                                             |

Unknown asset paths under `/assets/` return 404.

How each number is defined — active days, cohorts, dormancy, success rate, percentiles — is in
[Stored metrics](metrics.md#dashboard-definitions); the code that computes them is
`internal/stats/`.

## Snapshot of constants

Snapshot as of this writing — verify against the named source files.

| Constant                   | Value                               | Source                                                          |
| -------------------------- | ----------------------------------- | --------------------------------------------------------------- |
| Session lifetime           | 7 days                              | `internal/admin/sessions.go`                                    |
| Failed logins per address  | 5 per 15 minutes                    | `internal/admin/loginlimit.go`                                  |
| Failed logins overall      | 100 per hour                        | `internal/admin/loginlimit.go`                                  |
| Concurrent password checks | 2                                   | `internal/admin/server.go`                                      |
| argon2id parameters        | 64 MiB, 2 passes, 1 thread          | `internal/admin/password.go`                                    |
| Installs page size         | 50                                  | `internal/stats/installs.go`                                    |
| Dormant after              | 14 days without activity            | `internal/stats/installs.go`                                    |
| Weekly cohorts shown       | 12, each tracked to week 12         | `internal/admin/handlers_stats.go`, `internal/stats/cohorts.go` |
| Fleet window               | last 30 days; adoption over 90 days | `internal/stats/fleet.go`, `internal/admin/handlers_stats.go`   |
| Ban reason limit           | 200 characters                      | `internal/admin/handlers_stats.go`                              |
