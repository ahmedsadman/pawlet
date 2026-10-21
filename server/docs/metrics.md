# Stored metrics

What pawletd records for the admin dashboard, and what each value means. Nothing here is
derived from message content, the sender, the currency, or the caller's IP address.

## Scope

Two kinds of install reach the server:

- **Proxy-mode installs** (Play installs that passed Play Integrity attestation) mint sessions,
  make classify calls and report model stats. Everything about the verdict, calls, tokens and the
  on-device model describes these **attested installs** and the **proxy path** only.
- **Proxy and bring-your-own-key installs** both send heartbeats (see
  [Heartbeats](#heartbeats)), so activity days, last seen and app version also cover
  bring-your-own-key installs, including sideloaded ones. An install first seen through a
  heartbeat is stored **unattested**.

Installs in no-LLM mode never contact the server, messages the on-device model handles never
reach it, and a reinstall gets a new install ID — Play Console holds the real install count.

## Where it lives

The schema is versioned with SQLite's `user_version`. Migrations live in
`internal/store/migrations/` and run in order at pawletd startup (`internal/store/migrate.go`).
They are additive only, so an older image still runs against a newer database and rollback by
image tag stays safe.

| Table | One row per | Written by |
|---|---|---|
| `installs` | install | each successful `/v1/session` and each accepted `/v1/heartbeat` |
| `usage` | install per UTC day | `attempts`: every admitted classify request, retries included, with tokens on success, written by the quota flusher. `calls`: distinct messages, written on admission (see LLM calls under [Dashboard definitions](#dashboard-definitions)) |
| `llm_messages` | install per counted message key | each admitted classify request whose `messageKey` the install had not sent before; keys older than 30 days are pruned daily (`cmd/pawletd/prune.go`) |
| `install_days` | install per UTC day with a session or a heartbeat | each successful `/v1/session` and each accepted `/v1/heartbeat` |
| `counters_daily` | day, metric, key | metrics flusher (`internal/metrics/recorder.go`) |
| `model_stats_daily` | install per UTC day per app version | each accepted `/v1/model-stats` (replaces on resend) |
| `model_stats_rollup` | UTC day per app version | rollup job (`cmd/pawletd/rollup.go`) folds rows older than 90 days |
| `server_info` | configuration key | pawletd at startup |

## Install metadata

The verdict columns are taken from the latest Play Integrity verdict on every successful session
(`internal/httpapi/install_meta.go`) and overwritten each time, except that a verdict without a
version keeps the version already stored. A heartbeat never touches device tier, licensing or SDK.
NULL means the verdict did not carry the field, the install has not attested since the column was
added, or it has never attested at all.

| Column | Verdict field | Meaning |
|---|---|---|
| `app_version_code` | `appIntegrity.versionCode` | The app's Play versionCode. A heartbeat also sets it, to the version of the install's newest day that has one, so a late batch of old days cannot roll it back. |
| `device_tier` | `deviceIntegrity.deviceRecognitionVerdict` | `STRONG` or `DEVICE` — see below. |
| `licensing` | `accountDetails.appLicensingVerdict` | `LICENSED`, `UNLICENSED` or `UNEVALUATED` — see below. |
| `sdk_version` | `deviceIntegrity.deviceAttributes.sdkVersion` | Android API level. Only present when "device attributes" is enabled for the app in Play Console's Integrity API settings; NULL otherwise. |
| `messages_archived` | (not from verdict) | Total messages (accepted + declined + unavailable) folded into `model_stats_rollup`; updated by the rollup job (`internal/store/model_stats.go`). |
| `attested` | (not from verdict) | 1 once the install has minted a session, which needs a passing verdict; 0 for an install first seen through a heartbeat that has never minted one (bring-your-own-key, sideloaded). A session sets it to 1; a heartbeat never changes it. |

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

`first_seen` is when the server first heard from the install, by session or heartbeat. For an
install first seen through a heartbeat that is when the batch arrived, even if the batch carries
days up to 30 days old, so new-install counts follow arrival, not the oldest reported day.
`last_seen` moves on every successful session and every accepted heartbeat.

## Activity days

`install_days` holds one row per install per UTC day on which any signal arrived, with three
flags, the app version, and the LLM group (`internal/store/store.go`, `internal/store/heartbeat.go`):

| Column | Set by | Meaning |
|---|---|---|
| `opened` | heartbeat | The app came to the foreground that day. |
| `alive` | heartbeat | The app ran that day, in the foreground or the background. Always set when `opened` is. |
| `session` | `/v1/session` | The install minted a proxy session that day. Sessions are only minted in the foreground. |
| `app_version_code` | both | The version reported for that day. A heartbeat only moves it up (Play never downgrades an install); a session overwrites it unless its verdict carries no version. |
| `llm` | heartbeat | Which LLM group the install is in: `on` (Pawlet's server LLM), `off` (turned off), `byok` (own OpenRouter key), `none` (no LLM). Empty when not reported. Latest non-empty value wins; an empty value never clears the column. |

Flags only ever go from 0 to 1, so a resent or out-of-order heartbeat never clears one, and a
session leaves the heartbeat flags as they are. Version adoption over time is built from these
rows.

Migration `004_heartbeat.sql` added the three flags and `installs.attested` with a default of
**1**, not 0. Every row that existed before it came from a session minted in the foreground, so
the install was opened, alive and attested, and `ADD COLUMN` fills that in. An older pawletd
rolled back by image tag still only writes rows from foreground sessions, so its fresh inserts
stay correct, and its upserts don't touch the new columns. Every writer in the current binary
passes every flag explicitly. Under a rolled-back pawletd, a session on a heartbeat-first install
leaves `attested` = 0 until the next session after rolling forward, and a session on an existing
heartbeat day leaves that day's `session` flag at 0 (harmless: the app marks the day opened).

## Heartbeats

`POST /v1/heartbeat` (`internal/httpapi/heartbeat.go`) is how the app reports which days it was
opened or ran, independently of proxy sessions. It is **unauthenticated** by design: install
analytics must not depend on sessions, and bring-your-own-key installs never attest. The app only
sends it in proxy and bring-your-own-key modes, never in no-LLM mode.

The body is the install ID and up to 31 days, each with `day` (UTC `YYYY-MM-DD`),
`appVersionCode`, the booleans `opened` and `alive`, and the optional string `llm` (which LLM
group the install is in). The endpoint:

1. **checks the per-IP limit** — a fixed number per client IP per clock hour, with IPv6 addresses
   sharing one bucket per /64 network (`HEARTBEAT_PER_IP_HOUR`). Carrier NAT puts many phones
   behind one address, so the limit is generous;
2. **decodes strictly** — bounded size, no unknown fields, nothing after the JSON value;
3. **validates** — the install ID is 64 lowercase hex characters (what the app generates); each
   day is a real date inside the accepted window, has a version in range, sets at least one flag,
   and appears once; `llm` when present must be `on`, `off`, `byok` or `none`;
4. **stores** the days under the install ID's SHA-256 hash (the same hash `/v1/session` uses),
   in one transaction: the install is created unattested if it is new, otherwise only its
   `last_seen` moves (plus the version, see above). Banned installs are still recorded: a ban
   only refuses the LLM.

Success is **204 No Content**. Responses: `429 rate_limited` with `Retry-After` of one hour,
`400 bad_request` (malformed, too large or a validation rule broken), `503 internal` (the write
failed). The client IP is used for rate limiting but never logged or stored in the database.

## Daily counters

`counters_daily` holds aggregate counts with no install identity. Requests increment an
in-memory counter; the recorder writes the totals in one transaction on an interval and once
more at shutdown, and keeps failed writes for the next attempt. Metric names and keys are
defined in `internal/metrics/keys.go`.

| Metric | Keys | Counted when |
|---|---|---|
| `classify_outcome` | `ok`, `unauthorized`, `banned`, `bad_request`, `rate_limited_daily`, `rate_limited_burst`, `capacity`, `upstream_429`, `upstream_retryable`, `upstream_rejected`, `client_cancelled`, `internal` | every `/v1/classify` response, one key per request |
| `session_outcome` | `ok`, `bad_request`, `challenge_invalid`, `challenge_rate_limited`, `attest_unavailable`, `banned`, `internal`, `package_mismatch`, `request_hash_mismatch`, `stale_token`, `app_not_recognized`, `cert_mismatch`, `device_integrity`, `attest_failed` | every `/v1/session` response, plus `/v1/challenge` refusals for rate limiting |
| `model_stats_outcome` | `ok`, `unauthorized`, `banned`, `rate_limited`, `bad_request`, `internal` | every `/v1/model-stats` response, one key per request (`internal/metrics/keys.go`) |
| `heartbeat_outcome` | `ok`, `rate_limited`, `bad_request`, `internal` | every `/v1/heartbeat` response, one key per request |
| `classify_latency_ms` | bucket upper bounds (see snapshot) | successful classify calls |
| `model` | the model id OpenRouter reports serving, or `unknown` | successful classify calls |
| `category` | `transaction`, `bill`, `none` | successful classify calls |

Notes on keys:

- `unauthorized` covers every 401 on classify: missing or malformed header, bad or expired
  token, and a token for an install the server has no record of.
- `client_cancelled` counts classify calls whose classifier call failed after the request
  context was cancelled (client disconnect or server shutdown). The LLM client reports such a
  cancellation as a retryable upstream error, so without this key it would inflate the upstream
  failure counts. Only the counted key changes: the response the client receives is the same as
  for the underlying error.
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

pawlet-admin estimates percentiles from the bucket counts this way (`internal/stats/percentile.go`):
walk the buckets in order until the running total crosses the target rank (half of all calls for
p50, 95% for p95), then interpolate linearly inside that bucket. The result is an estimate within
one bucket's range — enough to spot a slow model or a trend, not a precise timing.

## Model stats and rollup

Proxy-mode installs (those that passed Play Integrity attestation) report daily counts of how the
on-device model handled messages via `/v1/model-stats` (`internal/httpapi/model_stats.go`). A
resend replaces the row's counts for that install-day-version, so the client can correct under- or
over-counting without creating duplicates.

`model_stats_daily` holds per-install-day counts for the last 90 days. Each row records:
- `accepted` — model prediction cleared the confidence gate, message handled locally
- `declined` — model ran but did not clear the gate; went to the LLM
- `unavailable` — model produced no prediction

The **rollup job** (`cmd/pawletd/rollup.go`) runs at startup and every 24 hours. In one
transaction it sums rows with `day` older than UTC today − 90 into `model_stats_rollup` (one row
per day per app version), adds each install's folded message total to `installs.messages_archived`,
then deletes the folded rows. The endpoint accepts days no older than 30, so a folded day can never
come back. Rollup failures are logged and retried next tick. `model_stats_rollup` rows are kept
forever.

Only proxy-mode installs report; bulk inbox import on first launch is not counted (it never goes
through the model).

How pawlet-admin turns these rows into the dashboard's local-model numbers is under
[Dashboard definitions](#dashboard-definitions).

## Server info

pawletd upserts its effective configuration into `server_info` at startup
(`cmd/pawletd/main.go`): daily per-install limit, burst limit, global daily cap, the model list,
the start time (unix seconds), and the image tag. The image tag comes from the `IMAGE_TAG`
environment variable, which `docker-compose.yml` passes through from the deploy and defaults to
`latest`; it is empty only when pawletd runs outside compose. Key names are in
`internal/store/server_info.go`.

## History

Install metadata fills in on each install's next session (about a day for active installs);
`install_days` and `counters_daily` start from the deploy that added them. The only backfill is
migration 004's defaults (see [Activity days](#activity-days)): rows from before it read as
opened, alive and session days of attested installs. Heartbeat-only days start with the first app
release that sends heartbeats; until an install updates to it, its activity days are session
days only.

## Snapshot of constants

Snapshot as of this writing — verify against the named source files.

| Constant | Value | Source |
|---|---|---|
| Counter flush interval | 10 s | `cmd/pawletd/main.go` |
| Latency bucket bounds (ms) | 250, 500, 1000, 2000, 4000, 8000, 16000, 32000, then `inf` | `internal/metrics/latency.go` |
| Day boundary | UTC | `internal/metrics/recorder.go`, `internal/store/store.go` |
| Per-install model stats retention | 90 days | `internal/store/model_stats.go` (`ModelStatsRetentionDays`) |
| Rollup interval | startup, then every 24 h | `cmd/pawletd/rollup.go` |
| `/v1/model-stats` body limit | 4 KB | `internal/httpapi/model_stats.go` |
| `/v1/model-stats` entries per request | 1–31 | `internal/httpapi/model_stats.go` |
| Accepted day window | UTC today − 30 … today + 1 | `internal/httpapi/model_stats.go` |
| Max count per field | 100,000 | `internal/httpapi/model_stats.go` |
| Per-install request limit | 12 per rolling hour | `internal/httpapi/installrate.go` |
| `/v1/heartbeat` per-IP limit (default) | 120 per clock hour (`HEARTBEAT_PER_IP_HOUR`), IPv6 per /64 | `internal/config/config.go`, `internal/httpapi/heartbeat.go` |
| `/v1/heartbeat` body limit | 4 KB | `internal/httpapi/heartbeat.go` |
| `/v1/heartbeat` days per request | 1–31 | `internal/httpapi/heartbeat.go` |
| `/v1/heartbeat` accepted day window | UTC today − 30 … today + 1 | `internal/httpapi/heartbeat.go` |
| Rolling window | 7 days, weighted | `internal/stats/localmodel.go` |
| Version marker minimum day volume | 20 messages | `internal/stats/localmodel.go` |
| Version marker majority | > 50 % of a day's messages | `internal/stats/localmodel.go` |
| Messages histogram buckets | 1, 2-3, 4-6, 7-10, 11-20, 21-50, 51+ | `internal/stats/distribution.go` |
| Messages histogram reach | last 90 days (per-install retention) | `internal/store/model_stats.go` (`ModelStatsRetentionDays`), applied in `internal/admin/handlers_stats.go` |
| Install detail message reach | last 90 days (per-install retention) | `internal/store/model_stats.go` (`ModelStatsRetentionDays`), applied in `internal/stats/installs.go` |

## Dashboard definitions

How pawlet-admin turns the stored data into numbers (`internal/stats/`).

- **Active day** (`internal/stats/activity.go`), chosen per request with `active=`:
  - **Running** (`any`): any `install_days` row for that day, whatever its flags (a heartbeat
    saying the app was opened or ran in the background, or a session), or a classify call.
  - **Opened** (`opened`): a day with `opened` or `session` set. Sessions are only minted in the
    foreground, and app builds without heartbeats report nothing else. Classify calls alone do
    not count: they also run in the background.
  - **Classify** (`classify`): classify calls only.

  Session days only exist since the capture deploy, so before that "Running" equals "Classify"
  and "Opened" is empty.
- **DAU / WAU / MAU** for a day: distinct installs active that day / in the 7 days / in the 30
  days ending that day. **Stickiness** is DAU divided by MAU.
- **Installs:** every install record; **attested** installs are those with `attested` = 1.
  **New installs** are grouped by the UTC day of `first_seen` (first heartbeat or session).
- **Cohorts:** installs grouped by the UTC ISO week (Monday start) of `first_seen`; each cell is
  the share of the cohort active (under the chosen mode) at least once in that later week.
- **Messages per active day:** every install-day with at least one message (summed across app
  versions), bucketed by its message count. It covers `max(range start, today − 89)` through
  today, because older per-install rows are folded into `model_stats_rollup` without install
  identity.
- **LLM calls** (`usage.calls`): messages sent to the LLM, each counted once. The app sends an
  opaque `messageKey` per message (hashed from its local row id and receive time, never the
  content), the same on every retry; the first admitted request with a key counts, on that day,
  even if every attempt then fails. Retries add nothing, even on a later day. A key is remembered
  for 30 days, so a retry after that counts again. Requests without a key (older app builds) count
  every time. The quota and the global cap charge every attempt (`usage.attempts`), so
  **quota-hit days** compare attempts with the daily limit, and the overview's cap meter shows
  today's attempts.
- **Dormant:** not banned, and no activity (latest of `last_seen` and the last day with classify
  requests)
  for more than 14 days. Both sessions and heartbeats move `last_seen`. The server cannot see uninstalls, so this stands in for churn.
- **Success rate:** `ok` divided by all classify outcomes that reached the LLM step (`ok`,
  `upstream_429`, `upstream_retryable`, `upstream_rejected`, `internal`). Client errors, quota
  denials and `client_cancelled` are left out.
- **Tokens per call:** usage tokens for the day divided by that day's `ok` count.
- **Fleet:** non-banned installs active ("Running") in the last 30 days. Versions cover all of
  them; the device tier, licensing and SDK charts cover attested installs only, because those
  values only come from a verdict. Missing values show as `unknown`. Version adoption counts
  `install_days` rows per version per day.
- **Installs table filters:** `status` (active, dormant, banned) and `attested` (`yes`, `no`, or
  all).

Local-model numbers (`internal/stats/localmodel.go`, `internal/stats/installs.go`,
`internal/stats/distribution.go`, `internal/stats/overview.go`), built from `model_stats_daily`,
`model_stats_rollup` and `installs.messages_archived`:

- **On-device rate** = `accepted` ÷ (`accepted` + `declined`). Model errors (`unavailable`) are
  counted but excluded. "No data" (null) when the denominator is 0, never 0 %.
- **Messages** = `accepted` + `declined` + `unavailable`. LLM calls are not added: every message
  passes the on-device model first. An install's lifetime total is its per-install rows plus
  `installs.messages_archived`; its per-day messages (and on-device counts) are null outside the
  last 90 days and for installs that never reported.
- **Previous-period rate:** the same rate over the equal-length period just before the range;
  none for "All".
- **7-day average** for a day = Σ`accepted` ÷ Σ(`accepted` + `declined`) over that day and the 6
  before it (weighted, not a mean of daily rates). It reaches before the range start.
- **Version marker:** a day whose majority version (more than half of the day's messages, on a
  day with at least 20 messages) differs from the last marked version. The first qualifying day
  sets the baseline without a marker.
- **Messages per active install-day** = messages in the range ÷ install-days with at least one
  message; rollup rows contribute their `install_count`. Shown next to calls per active
  install-day (calls ÷ install-days with at least one classify request).

Caveats that apply to every number: no-LLM installs are invisible, and verdict, call and model
numbers cover attested proxy-mode installs only (see Scope). Heartbeats are unauthenticated, so an
unattested install could be faked; filter to attested installs to exclude them. The app uploads a
heartbeat only when a day's record changes, at most about once an hour, so `last_seen` usually
moves once or twice a day and "today" can lag up to a day; days spent offline arrive late. A fresh
install sends nothing for its first 6 hours, so it appears that much later or more.
Installs on app versions without heartbeats count only their session days, which undercount daily
opens because the 24-hour token is only refreshed near expiry. Classify activity follows SMS volume
rather than engagement, and a reinstall appears as a new install.
