# Local-model stats

Play installs on Pawlet's proxy record what the on-device model decided for every live message it ran on, and send
the daily counts to the server, where the admin dashboard turns them into the on-device rate and the total
message volume.

## Verdicts

| Verdict       | Meaning                                                                                   |
| ------------- | ----------------------------------------------------------------------------------------- |
| `accepted`    | The model's output cleared the confidence gate (financial or not); the LLM is not called. |
| `declined`    | The model ran but did not clear the gate; the message goes to the LLM.                    |
| `unavailable` | The model produced no prediction (failed to load or to run); the message goes to the LLM. |

What the LLM does afterwards (success, error, retry, waiting for the network) never changes the verdict.

## Counting

- Done in `ProcessingService` (`lib/services/processing_service.dart`) right after the on-device pass, through
  `ModelStatsRepository.recordVerdict` (`lib/data/model_stats_repository.dart`).
- One transaction sets `sms_records.local_verdict` only while it is empty, and only then increments the matching
  column of the `model_stats` row for (UTC day, app version code). A message is therefore counted exactly once:
  retries, rows reclaimed after a crash and the Retry action find the verdict already set.
- Rows that skip inference because `needs_llm` is set are not counted again. Rows that existed before schema
  version 7 start with no verdict, so they are counted only if the model runs on them after the upgrade.
- Not counted: messages the sender gate rejects (no model ran), and the bulk inbox import
  (`lib/services/bulk_import/bulk_import_service.dart`), which does not go through `ProcessingService`.
- The app version code is the `package_info_plus` build number (`lib/services/app_version.dart`). If it cannot be
  read, the message is not counted.
- Counting runs only in proxy mode. Before each verdict is counted, `ProcessingService` re-checks the mode with the
  same check the reporter runs before each send (built in `lib/services/app_services.dart`, which offers it only to
  proxy-mode services). BYOK installs count nothing, so BYOK usage can never reach the server, even if the install
  later becomes proxy-eligible. In no-LLM mode nothing is counted either: the model runs without its confidence gate,
  so its answers are not comparable. If the check fails, the message is not counted.
  Counting never changes what happens to the message: a counting failure is swallowed.

Schema: `sms_records.local_verdict` and the `model_stats` table, both in `lib/data/database.dart`.

## Reporting

`ModelStatsReporter` (`lib/services/model_stats_reporter.dart`) sends the counts to the server's
`POST /v1/model-stats`.

- Built only in proxy mode (`lib/services/app_services.dart`). BYOK and no-LLM installs neither count nor send.
- Before every send the reporter re-checks that the install is still in proxy mode, resolving the mode from freshly
  reloaded settings (attestation can flag the install ineligible, possibly from another isolate, while the services
  live on). If it is not, nothing is sent and the throttle is not started.
- Triggers: the end of every `ProcessingService.process()` pass, in whichever isolate ran it (UI, background SMS or
  WorkManager), and app resume (`lib/app.dart`). The pass-end flush runs after the pass releases its overlap guard,
  so it never makes a new pass wait.
- One flush at a time per isolate. Across isolates, a flush only goes out once the throttle window since the last
  acknowledged flush has passed; the time is kept in the `app_meta` key `model_stats_flushed_at`.
- Payload: `model_stats` rows never sent, or changed since they were last acknowledged, inside the retention window.
  If there are more than the row cap, the newest rows go first.
- Uses the proxy session token from `AttestationService` (`lib/services/auth/attestation_service.dart`). A
  background isolate cannot mint a session, so without a usable token it sends nothing and waits for the next
  trigger.
- A row is marked sent only if its counts did not change while the request was in flight, so a verdict counted
  mid-flush goes out with the next flush.
- Errors never reach message processing.

| Server answer                | What the reporter does                                           |
| ---------------------------- | ---------------------------------------------------------------- |
| 2xx                          | Marks the rows sent and starts the throttle window               |
| 401                          | Forces a new session once and resends once; otherwise waits      |
| 403                          | Nothing; waits for the next trigger                              |
| 400                          | Marks the rows sent, so a rejected payload is not resent forever |
| Anything else, or no network | Nothing; retried on the next trigger                             |

## Retention

`model_stats` rows older than the retention window are deleted whenever a verdict is counted and on every flush that
gets past the throttle. Neither `model_stats` nor the reporter's `app_meta` key is part of a backup
([Backup & Restore](backup-restore.md)).

## Constants

Snapshot — the source files are authoritative.

| Constant                                 | Value                            | Source                                                                         |
| ---------------------------------------- | -------------------------------- | ------------------------------------------------------------------------------ |
| Minimum gap between acknowledged flushes | 6 h                              | `lib/services/model_stats_reporter.dart` (`ModelStatsReporter.minGap`)         |
| Rows per request                         | 31                               | `lib/services/model_stats_reporter.dart` (`ModelStatsReporter.maxDays`)        |
| Request timeout                          | 20 s                             | `lib/services/model_stats_reporter.dart` (`ModelStatsReporter.requestTimeout`) |
| Days kept and sent                       | UTC today and the 30 days before | `lib/data/model_stats_repository.dart` (`kModelStatsRetentionDays`)            |
