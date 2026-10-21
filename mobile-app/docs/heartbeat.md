# Heartbeat

The app keeps a small per-day log of whether it ran and whether it was opened, and sends it to Pawlet's server's
`POST /v1/heartbeat`. That is what lets the admin dashboard count active and retained installs without depending on
proxy sessions, including bring-your-own-key installs that never attest.

| Piece                                                        | Role                                                             |
| ------------------------------------------------------------ | ---------------------------------------------------------------- |
| `lib/services/heartbeat.dart`                                | `Heartbeat` facade, `syncHeartbeat`, the daily task's body       |
| `lib/data/heartbeat_repository.dart`                         | The `heartbeat_days` log and the upload's `app_meta` bookkeeping |
| `lib/services/heartbeat_reporter.dart`                       | Uploads the log                                                  |
| `lib/services/upload_backoff.dart`, `lib/data/app_meta.dart` | Retry pacing and schedule stamps shared with model stats         |
| `lib/services/background_worker.dart`                        | Registers and cancels the daily WorkManager task                 |

## What is recorded

One `heartbeat_days` row per UTC day (schema version 11, `lib/data/database.dart`): the day, the build's version code,
`opened` and `alive`, the LLM group (column `llm_group`, sent on the wire as `llm`: `on`/`off`/`byok`/`none`, latest value of the day wins), plus the `updated_at` and `reported_at` timestamps the reporter uses. Nothing else: no message,
category, amount or any other setting.

- **Opened** is marked when the app comes to the screen: at launch and on every resume (`lib/app.dart`).
- **Alive** is marked at the end of every processing pass, in whichever isolate ran it (UI, background SMS or
  WorkManager), and by the daily task. Opening the app marks it alive too, and so does every rebuild of the UI
  isolate's services (`appServicesProvider` in `lib/state/providers.dart`, which rebuilds on a mode change), so today's
  row takes the new LLM group without waiting for the next pass.

Flags only ever turn on, and the row takes the version of the build running, read from `package_info_plus`
(`lib/services/app_version.dart`); if the version cannot be read, nothing is marked, since filing a day under the wrong
build would be worse than missing it. The row's `updated_at` moves only when a mark actually changes it, so the repeat
marks of every resume and every pass leave nothing new to send.

`HeartbeatRepository.mark` reads the day's row and then inserts or updates it, in one transaction, instead of using an
SQLite upsert: `ON CONFLICT DO UPDATE` needs SQLite 3.24, which Android ships only from Android 11, while the app
supports Android 7.

Marking never throws and never holds up launch, resume or a processing pass.

## The daily task

`BackgroundWorker.scheduleHeartbeat` registers a periodic WorkManager task every 24 hours. It is the one background
wake the app has when no messages are queued: without it, an install that is never opened and gets no bank SMS would
look uninstalled.

- It marks today alive and lets the reporter try an upload. It runs no processing pass.
- It has **no network constraint**: marking is local, and an upload that cannot go out is retried on a later mark.
- It is registered with `ExistingPeriodicWorkPolicy.update`, so re-registering on every launch keeps its schedule.
- It always reports success, so WorkManager never retries it.
- It resolves the mode itself from freshly reloaded settings.

## Mode gating

Heartbeats are sent in **every mode** (proxy, opted-out, bring-your-own-key, none), in builds that set `PAWLET_API_BASE`
(`BuildConfig.apiBaseConfigured`); that includes debug builds run with `dart_define.json`, which point at the live
server. Builds without a server send nothing ([LLM modes](llm-modes.md)).

- `AppServices` (`lib/services/app_services.dart`) builds the `Heartbeat` in every mode when the build has a server; otherwise there is no `Heartbeat`, and nothing is marked.
- Every mark resolves the LLM group from freshly reloaded settings and the keystore (`AppServices.heartbeatGroup`),
  since the mode can change in another isolate while the services live on. If that resolution fails, the group is
  resolved from the settings already loaded, as if no key were saved, so the mark is kept; a bring-your-own-key
  install then files that day as `none` until a later mark resolves normally. An unreadable keystore already reads as
  no key (`SecureStore.readApiKey`). The reporter itself does not check the mode.
- `syncHeartbeat` runs whenever the UI isolate resolves the mode (`appServicesProvider` in
  `lib/state/providers.dart`). When the build has a server it schedules the daily task; otherwise it cancels the task.

## Uploading

Every mark asks the reporter to flush. A flush goes out only when all of these hold:

1. No flush is already running in this isolate (a second caller shares it).
2. No failed upload is being backed off (see [Backoff](#backoff)).
3. Some row was never acknowledged, or changed since. Rows dated after UTC tomorrow (a phone clock running ahead) are
   held back until they fall inside the server's window, so they cannot get the whole batch rejected.
4. The app was first installed at least the first-upload delay ago (`PackageManager.firstInstallTime`, read through
   `readInstallTime` in `lib/services/app_version.dart`). Play's review and scanning devices run each new build for a
   few minutes and are then wiped, so without the delay they show up as installs. An update keeps the install time, so
   only fresh installs and reinstalls wait; their held days stay in the log and go with a later flush. An unknown
   install time, or one in the future (the clock moved back), holds nothing off.
5. The last acknowledged flush, from any isolate, was at least the minimum gap ago, unless the newest row is from a
   build the server has not been told about yet.

The request is unauthenticated: it carries the install ID, which the server hashes before storing, exactly as
`/v1/session` does. So it works from background isolates and in bring-your-own-key mode, neither of which can mint a
session. If the install ID cannot be read from the keystore, the rows are kept and no backoff starts. At most the row
cap goes per request; when more qualify, the newest go first and the rest wait for a later flush. A row is marked sent
only if it did not change while the request was in flight.

Because a flush needs both a changed row and a mark to trigger it, an install typically uploads when a day's first
alive or first open happens, when it is opened after only running in the background, and when a new build runs. A
change that lands inside the minimum gap waits for the next mark (launch, resume, processing pass or daily task). On
the server, `last_seen` therefore usually moves once or twice a day, and "today" can lag by up to a day. A fresh
install first appears on the server at the first mark after the delay ends, which can be as late as the next daily
task.

| Server answer                        | What the reporter does                                                                    |
| ------------------------------------ | ----------------------------------------------------------------------------------------- |
| 2xx                                  | Marks the rows sent, starts the throttle window, records the build, clears backoff        |
| 400                                  | Marks the rows sent (a rejected payload is not resent), records the build, clears backoff |
| 429                                  | Waits as long as `Retry-After` says, clamped; doubling wait if it is absent               |
| anything else, timeout or no network | Doubling wait                                                                             |

### Backoff

Shared with the model-stats upload through `UploadBackoff` (`lib/services/upload_backoff.dart`), with its own
`app_meta` keys shared by every isolate (`lib/data/heartbeat_repository.dart`): `heartbeat_failures` (uploads failed
in a row), `heartbeat_retry_at` (earliest next attempt), `heartbeat_flushed_at` (start of the last acknowledged
flush) and `heartbeat_reported_version` (the build of the newest day last acknowledged).

- Doubling wait: the base wait, doubled for each consecutive failure after the first, up to the cap. No jitter.
- `Retry-After` is read as seconds or as an HTTP date, and clamped between the minimum and the cap.
- A retry time further ahead than the cap, or a flush stamp in the future (the clock moved back), is ignored.

## Retention

The log keeps UTC today and the 29 days before, the same window as the local-model stats
([Local-model stats](model-stats.md)), so it stays inside the server's accepted window. Older rows are deleted on every
mark and on every flush that gets past the backoff. Neither `heartbeat_days` nor its `app_meta` keys are part of a
backup ([Backup & Restore](backup-restore.md)).

## Constants

Snapshot — the source files are authoritative.

| Constant                                 | Value                            | Source                                                                        |
| ---------------------------------------- | -------------------------------- | ----------------------------------------------------------------------------- |
| Minimum gap between acknowledged flushes | 1 h (skipped for a new build)    | `lib/services/heartbeat_reporter.dart` (`HeartbeatReporter.minGap`)           |
| First-upload delay after install         | 6 h                              | `lib/services/heartbeat_reporter.dart` (`HeartbeatReporter.firstUploadDelay`) |
| Rows per request                         | 31                               | `lib/services/heartbeat_reporter.dart` (`HeartbeatReporter.maxDays`)          |
| Request timeout                          | 20 s                             | `lib/services/heartbeat_reporter.dart` (`HeartbeatReporter.requestTimeout`)   |
| Days kept and sent                       | UTC today and the 29 days before | `lib/data/model_stats_repository.dart` (`kModelStatsRetentionDays`)           |
| Daily task period                        | 24 h                             | `lib/services/background_worker.dart` (`scheduleHeartbeat`)                   |
| Backoff base wait (first failure)        | 15 min                           | `lib/services/upload_backoff.dart` (`kUploadBackoffBase`)                     |
| Backoff cap                              | 6 h                              | `lib/services/upload_backoff.dart` (`kUploadBackoffCap`)                      |
| Shortest `Retry-After` wait              | 1 min                            | `lib/services/upload_backoff.dart` (`kUploadRetryAfterMin`)                   |
