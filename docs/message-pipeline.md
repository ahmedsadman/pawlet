# Message pipeline

How an incoming SMS travels from arrival to a stored finance record — capture,
queueing, processing, and the offline / reconnect / retry behavior that keeps it
reliable on a phone with flaky connectivity.

The design principle throughout: **capture and processing are separate**. A message is
persisted the instant it arrives, then processed as a distinct step, so nothing is lost
if the phone is offline, the model is rate-limited, or the app is killed mid-way.

## Component map

| Concern | File |
|---|---|
| Incoming-SMS registration (foreground + background isolate) | `lib/services/sms_listener.dart` |
| Capture + wiring (the entry points that persist and kick off processing) | `lib/services/app_services.dart` |
| Queue drain, retry/backoff policy | `lib/services/processing_service.dart` |
| Queue persistence + queries (claim, due, stale, prune) | `lib/data/sms_repository.dart` |
| Record shape + lifecycle states | `lib/models/sms_record.dart` |
| Layer-1 gate + fused LLM orchestration | `lib/services/classification/classifier.dart`, `lib/services/classification/sender_matcher.dart` |
| The single LLM call + HTTP error/hint parsing | `lib/services/llm/openrouter_provider.dart` |
| Persisting the classified result | `lib/services/finance/finance_writer.dart` |
| Connectivity check | `lib/services/connectivity_service.dart` |
| Background catch-up scheduling | `lib/services/background_worker.dart` |
| Failure / retry notifications | `lib/services/notification_service.dart` |

## 1. Capture — receiving an SMS

Three sources feed the same entry point (`AppServices.handleIncomingRaw`):

- **App alive (foreground or backgrounded):** the telephony plugin's `onNewMessage`
  callback fires in the UI isolate.
- **App killed:** the plugin spins up a **fresh background isolate** and calls
  `backgroundSmsHandler`. A new isolate can't share the UI isolate's objects, so it
  builds its own service bundle from scratch (`AppServices.bootstrap` — own database
  handle, own HTTP client, own plugin registration) and disposes it when done.
- **Debug injector:** `adb` broadcasts a fake message that arrives over the
  `meowni/debug` method channel (debug builds only). See the app README.

Capture then does, in order:

1. **Normalize** — trim the sender, convert CRLF/CR to LF and trim the body. Empty
   sender or empty body is dropped.
2. **Resolve contact** (optional) — look up a contact name for the sender when the
   setting is on.
3. **Persist, deduped** — insert into the queue. A unique index on
   `(sender, timestamp, content)` means overlapping foreground / background / cold-start
   reads of the *same* SMS collapse to one row (duplicate inserts are ignored).
4. **Kick off processing** — call the queue drain immediately.

A freshly captured row starts in status **`queued`**. Storage cleanup no longer runs on
capture — it moved into the drain pass as a throttled step (§3, §9).

## 2. The queue and a record's lifecycle

Every message is a row in `sms_records`, which doubles as the queue. Its `status` moves
through five states:

```
        claim (atomic)                    reschedule (retryable,
   ┌───────────────────►────────────┐      attempts++, backoff)
   │                                 │  ┌──────────────────────┐
 queued ◄──────────────────────── sending ◄───────────────────┘
   ▲   reschedule / reclaimStale      │
   │   (orphaned >3 min → requeued)   ├──►  success   (wrote a finance record)
   │                                  ├──►  ignored   (processed, not financial)
   └──────────────────────────────── └──►  failure   (fatal, or attempts == max)
```

- **`queued`** — waiting to run. Also the resting state *between* retries (with a future
  `next_attempt_at`).
- **`sending`** — claimed and in flight (gate + LLM call).
- **`success`** — processed and written to a finance record (`transaction` or `bill`).
- **`ignored`** — processed but deliberately not a financial record. Terminal, but kept
  only briefly (§9). Invisible in History.
- **`failure`** — gave up (hit max attempts, or a fatal error). Shown in History with a
  short reason hint.

A **category label** (`transaction` / `bill`) is stored only on `success` rows.

Two internal, debug-only reason columns explain terminal non-success outcomes (see
`lib/models/sms_record.dart`):

- **`ignore_reason`** on `ignored` rows — `gated` (Layer-1 gate rejected it, no LLM call),
  `llm_none` (the model said "not financial"), or `no_record` (the model classified it as
  financial but no row was written — missing metadata, unmatched card, or a duplicate).
- **`failure_reason`** on `failure` rows — `llm_error` (fatal) or `retry_exhausted`. The
  underlying error text is stored (truncated) in `last_error`; both are internal (read via
  ADB/debug), never surfaced in the UI. History shows only a short hint derived from
  `failure_reason`.

Queue queries that matter:

- **Due now** — `queued` rows whose `next_attempt_at` is null or already past, oldest
  SMS first (by receive time, not by retry time).
- **Claim** — a single atomic `queued → sending` update that returns true only for the
  winner. This is what makes concurrent isolates (UI + background) safe: two can't
  process the same row.
- **Reclaim stale** — a `sending` row untouched for longer than the stale window is
  assumed orphaned (its isolate was killed mid-flight) and returned to `queued`.

## 3. Processing one message

A drain pass (`ProcessingService.process`) is **single-flight per isolate** (a re-entrant
call while one is running is ignored) and, before touching anything, requeues stale
`sending` rows. It then walks the due list and processes each:

1. **Online check** — if offline, stop immediately (see §5).
2. **Claim** the row (`queued → sending`). Losing the claim means another isolate has it;
   skip.
3. **Classify** (`Classifier`):
   - **Layer-1 gate (local, free):** does the sender match one of your banks' matchers,
     or does the body contain one of your registered card numbers? If not, the message is
     **ignored with no LLM call** — this is what stops OTPs, promos, and personal texts
     from spending API quota.
   - **Fused LLM call:** a message that passes the gate goes to a *single* OpenRouter
     request carrying a static ordered fallback list of structured-output-capable models
     (from `SettingsRepository.defaultLlmModels`). The request uses strict structured
     output (`response_format: {type: json_schema, json_schema: <schema>}`) with
     `provider: {require_parameters: true}` so every fallback hop enforces the schema.
     OpenRouter tries the models in order server-side within the single request. One
     attempt, no internal retry loop — transient failures surface as exceptions for the
     queue to retry (§7).
4. **Write** (`FinanceWriter`) — persist the result in one DB transaction (balance update
   and row insert commit together or not at all). Returns the category label, or
   `ignored` when nothing was written.
5. **Mark terminal** — `next_attempt_at` cleared, `processed_at` set. A written record →
   `success` with its category; an `ignored` label → status `ignored` with the matching
   `ignore_reason`.

After the queue drains, deferred **relationship matchers** run once (transfer pairing,
credit-card-payment ↔ bill), then failure/retry **counts** are reconciled into
notifications, a **throttled prune** runs (§9), and the next background catch-up is
(re)scheduled (§6).

## 4. What triggers a drain

`process()` has no timer of its own. It runs when *something happens*:

| Trigger | Where |
|---|---|
| App startup / first foreground | `RootShell` bootstrap in `lib/app.dart` |
| App returns to foreground (resume) | lifecycle observer in `lib/app.dart` |
| An SMS arrives while the app is alive | `handleIncomingRaw` in `app_services.dart` |
| An SMS arrives while the app is killed | `backgroundSmsHandler` isolate |
| Pull-to-refresh on the Messages screen | `lib/ui/messages_page.dart` |
| Manual per-message retry | `AppServices.retryMessage` |
| Scheduled background catch-up | `callbackDispatcher` in `background_worker.dart` |

## 5. Offline behavior

Being offline must never *cost* a message an attempt. Three guards enforce that:

- **Pass never starts offline.** If `process()` sees no connectivity, it schedules a
  catch-up and returns — no rows are claimed, no attempts spent.
- **Drain stops the moment connectivity drops.** Inside the loop, each record rechecks
  connectivity before claiming; the first offline check ends the pass, leaving the
  remaining rows `queued` and due.
- **A failure discovered to be offline is a transport drop, not an attempt.** If the LLM
  call fails and a recheck shows the device went offline, the row is released back to
  `queued` **with its `attempts` and `next_attempt_at` unchanged**. The backoff ladder is
  not advanced for something the network, not the server, broke.

Net effect: an offline backlog simply waits, fully intact, for the next drain.

## 6. Reconnecting — what happens when the internet comes back

There is **no foreground "connectivity restored" listener**. (A connectivity stream
exists in `connectivity_service.dart` but is intentionally unused for triggering drains.)
Recovery comes from two mechanisms instead:

- **Network-constrained background catch-up (primary).** After every pass, the pipeline
  reschedules a *single* one-off WorkManager task for the soonest queued attempt — or
  cancels it entirely when the queue is empty. Crucially the task carries a
  **"network connected" constraint**, so an offline backlog schedules a catch-up at
  delay zero and the OS simply holds it until connectivity returns, then runs it. An idle
  app with an empty queue schedules nothing and never wakes.
- **Ambient foreground triggers.** Any of the §4 triggers (resume, a new SMS,
  pull-to-refresh) re-runs the drain, which now finds the device online and clears the
  backlog.

This is the "adaptive wakeup" behavior: background work is scheduled *only when there is
pending work*, gated on the network, and cancelled when the queue drains.

## 7. Retry and backoff

### Retryable vs. fatal

The provider makes exactly one HTTP attempt and classifies the outcome:

| Outcome | Class | Queue action |
|---|---|---|
| HTTP 429 (rate limit), 408, any 5xx | retryable | back off and retry |
| Network error / timeout (2 min) | retryable | back off and retry |
| Malformed or unexpected JSON | retryable | back off and retry |
| Other 4xx — bad key (401), bad request (400) | **fatal** | mark `failure` immediately |
| Unexpected non-LLM error (e.g. DB) | retryable | back off and retry |

### The backoff ladder

`attempts` counts *real* attempts (offline drops don't count). Each retryable failure
increments it and schedules the next run:

```
backoff(attempt) = min(6h, 15s × 4^(attempt − 1))
next_attempt_at  = now + max(server_hint, backoff(attempt))
```

| attempt | delay |
|---|---|
| 1 | 15s |
| 2 | 1m |
| 3 | 4m |
| 4 | 16m |
| 5 | ~1h 4m |
| 6 | ~4h 16m |
| 7–9 | 6h (capped) |
| 10 | give up → `failure` |

That's roughly **23.7 h of retrying** spread across nine attempts before a message is
abandoned.

### Server retry hints

On a 429/503 OpenRouter may send one of two headers; both are honored **without needing a
clock**:

- **`Retry-After`** — a relative delay in seconds (only the integer-seconds form is
  used; HTTP-date form is ignored because it would require a trusted clock).
- **`X-RateLimit-Reset`** — an absolute epoch timestamp in **milliseconds**, carried
  as-is and converted to a delay by subtracting "now".

The larger of the two becomes a hint, which is clamped to a 24 h ceiling (guarding
against clock skew or a misparsed unit parking a row absurdly far out). The actual delay
is then `max(hint, backoff)`: the server's "don't retry before" is respected, but retries
never fire *faster* than the backoff ladder would allow, and escalation is preserved.

> Note on `X-RateLimit-Reset` units: OpenRouter sends epoch **milliseconds** (13-digit),
> confirmed empirically — the docs omit the unit.

### Manual retry

Retry is **per-message**: each `failure` row in History has its own retry control
(`AppServices.retryMessage`) that returns just that message to `queued` with `attempts`
preset to one below the max, so the next drain gives it exactly **one** more shot; if it
fails again it lands back in `failure`. Queued messages that have already failed at least
once show their retry progress (Retry n/10) and, while a next attempt is still upcoming,
the scheduled next-attempt time.

## 8. Notifications

After each drain the pipeline reconciles the failed count into a notification:

- **Failed** — rows in `failure`. A notification fires when messages reach this terminal
  state.

## 9. Retention

Storage is bounded by a **throttled prune** that runs at the end of a drain pass (§3),
not on capture. `pruneIfDue` (`lib/data/sms_repository.dart`) does at most one real prune
per 24 h, coordinated across every trigger and both isolates by a single timestamp row in
`app_meta` (`last_prune_at`): if the last prune was under the gap ago, the call is a no-op.

What it deletes:

- **`ignored`** rows older than **7 days**.
- Nothing else. **`success` and `failure` rows are permanent.**

Keeping financial (`success`) rows forever also removes a class of bug: transactions/bills
`INNER JOIN sms_records`, so pruning a backing SMS used to make its record vanish from the
list while still counting in totals. Failures are kept so the user can always see *why* a
message didn't process.

## Tuning constants

Values are defined in code; this table is a snapshot — check the source if precision
matters, since numbers can drift.

| Constant | Value | Defined in |
|---|---|---|
| Max attempts before giving up | 10 | `processing_service.dart` |
| Base backoff | 15s | `processing_service.dart` |
| Backoff multiplier | ×4 per attempt | `processing_service.dart` |
| Max single backoff step | 6h | `processing_service.dart` |
| Server-hint ceiling | 24h | `processing_service.dart` |
| Stale `sending` reclaim window | 3 min | `processing_service.dart` |
| LLM single-attempt HTTP timeout | 2 min | `openrouter_provider.dart` |
| Ignored retention | 7 days | `sms_repository.dart` |
| Prune throttle gap | 24h | `sms_repository.dart` |

The stale window (3 min) is deliberately kept **above** the HTTP timeout (2 min) so a
genuinely slow in-flight call is never reclaimed as orphaned mid-flight — which would risk
double-processing across isolates.
