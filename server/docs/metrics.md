# Stored metrics

What pawletd records for the admin dashboard, and what each value means. Nothing here is
derived from message content, the sender, the currency, or the caller's IP address.

## Scope

The server only sees installs in proxy mode: Play installs that passed Play Integrity
attestation. Sideloaded and bring-your-own-key installs call OpenRouter directly, and
messages the on-device model handles never reach the server. So every number here describes
**attested installs** and the **proxy path**, not the whole user base — Play Console holds the
real install count.

## Where it lives

The schema is versioned with SQLite's `user_version`. Migrations live in
`internal/store/migrations/` and run in order at pawletd startup (`internal/store/migrate.go`).
They are additive only, so an older image still runs against a newer database and rollback by
image tag stays safe.

| Table | One row per | Written by |
|---|---|---|
| `installs` | install | each successful `/v1/session` |
| `usage` | install per UTC day | admitted classify calls (tokens on success), written by the quota flusher |
| `install_days` | install per UTC day with a successful session | each successful `/v1/session` |
| `counters_daily` | day, metric, key | metrics flusher (`internal/metrics/recorder.go`) |
| `server_info` | configuration key | pawletd at startup |

## Install metadata

Taken from the latest Play Integrity verdict on every successful session
(`internal/httpapi/install_meta.go`) and overwritten each time. NULL means the verdict did not
carry the field, or the install has not attested since the column was added.

| Column | Verdict field | Meaning |
|---|---|---|
| `app_version_code` | `appIntegrity.versionCode` | The app's Play versionCode. |
| `device_tier` | `deviceIntegrity.deviceRecognitionVerdict` | `STRONG` or `DEVICE` — see below. |
| `licensing` | `accountDetails.appLicensingVerdict` | `LICENSED`, `UNLICENSED` or `UNEVALUATED` — see below. |
| `sdk_version` | `deviceIntegrity.deviceAttributes.sdkVersion` | Android API level. Only present when "device attributes" is enabled for the app in Play Console's Integrity API settings; NULL otherwise. |

`install_days` also keeps the version seen on each session day, which is what version
adoption over time is built from.

### Device tier

Google's judgement of how trustworthy the phone is:

- `MEETS_BASIC_INTEGRITY` — passes basic checks, but may be rooted, an emulator, or running a
  custom ROM.
- `MEETS_DEVICE_INTEGRITY` — a genuine, Play-certified Android device.
- `MEETS_STRONG_INTEGRITY` — device integrity plus hardware-backed proof of boot integrity
  and, on recent Android versions, a security patch from the last year.

The server **requires** device integrity (`internal/attest/verify.go`), so a basic-only
install never gets a session and never reaches this table. `device_tier` therefore only splits
`STRONG` (modern, patched phone) from `DEVICE` (genuine but older or unpatched).

### Licensing

How the app got onto the device:

- `LICENSED` — the user installed it from Play.
- `UNLICENSED` — not acquired through Play, for example a Play-signed APK copied from another
  phone or an APK mirror. It still passes the signing-certificate check, because it is the same
  binary.
- `UNEVALUATED` — Google could not decide, for example because device requirements were not
  met.

The server records licensing but does not enforce it.

## Daily counters

`counters_daily` holds aggregate counts with no install identity. Requests increment an
in-memory counter; the recorder writes the totals in one transaction on an interval and once
more at shutdown, and keeps failed writes for the next attempt. Metric names and keys are
defined in `internal/metrics/keys.go`.

| Metric | Keys | Counted when |
|---|---|---|
| `classify_outcome` | `ok`, `unauthorized`, `banned`, `bad_request`, `rate_limited_daily`, `rate_limited_burst`, `capacity`, `upstream_429`, `upstream_retryable`, `upstream_rejected`, `client_cancelled`, `internal` | every `/v1/classify` response, one key per request |
| `session_outcome` | `ok`, `bad_request`, `challenge_invalid`, `challenge_rate_limited`, `attest_unavailable`, `banned`, `internal`, `package_mismatch`, `request_hash_mismatch`, `stale_token`, `app_not_recognized`, `cert_mismatch`, `device_integrity`, `attest_failed` | every `/v1/session` response, plus `/v1/challenge` refusals for rate limiting |
| `classify_latency_ms` | bucket upper bounds (see snapshot) | successful classify calls |
| `model` | the model id OpenRouter reports serving, or `unknown` | successful classify calls |
| `category` | `transaction`, `bill`, `none` | successful classify calls |

Notes on keys:

- `unauthorized` covers every 401 on classify: missing or malformed header, bad or expired
  token, and a token for an install the server has no record of.
- `client_cancelled` counts classify calls where the request context was cancelled (client
  disconnect or server shutdown) before the call finished.
- `upstream_retryable` also covers an unexpected classifier error that is not an OpenRouter
  call error; both answer the client with 503 `upstream`.
- The `session_outcome` verification keys map one-to-one to the errors in
  `internal/attest/verify.go`. `attest_failed` catches a verification error without its own key.
- Model keys are truncated at 128 bytes on a UTF-8 rune boundary
  (`internal/httpapi/classify.go`) to cap each key's size: every distinct key becomes a
  permanent row. The number of distinct model keys is limited in practice because OpenRouter
  only serves the configured models.

### Latency buckets

Each successful classify call is timed from the start of the handler to the response, then
counted under the **smallest bucket bound it fits under** (`internal/metrics/latency.go`). The
row `classify_latency_ms / 2000 / 2210` means 2210 calls that day took more than 1 s and at
most 2 s. Calls over the last bound go to `inf`.

The admin dashboard is intended to estimate percentiles from the bucket counts: walk the buckets
in order until the running total crosses the target rank (half of all calls for p50, 95% for
p95), then interpolate linearly inside that bucket. The result is an estimate within one bucket's
range — enough to spot a slow model or a trend, not a precise timing. (This percentile estimation
is not yet implemented in pawletd; it describes how the dashboard should read the buckets.)

## Server info

pawletd upserts its effective configuration into `server_info` at startup
(`cmd/pawletd/main.go`): daily per-install limit, burst limit, global daily cap, the model list,
the start time (unix seconds), and the image tag. The image tag comes from the `IMAGE_TAG`
environment variable, which `docker-compose.yml` passes through from the deploy and defaults to
`latest`; it is empty only when pawletd runs outside compose. Key names are in
`internal/store/server_info.go`.

## History

Nothing is backfilled. Install metadata fills in on each install's next session (about a day
for active installs); `install_days` and `counters_daily` start from the deploy that added them.

## Snapshot of constants

Snapshot as of this writing — verify against the named source files.

| Constant | Value | Source |
|---|---|---|
| Counter flush interval | 10 s | `cmd/pawletd/main.go` |
| Latency bucket bounds (ms) | 250, 500, 1000, 2000, 4000, 8000, 16000, 32000, then `inf` | `internal/metrics/latency.go` |
| Day boundary | UTC | `internal/metrics/recorder.go`, `internal/store/store.go` |
