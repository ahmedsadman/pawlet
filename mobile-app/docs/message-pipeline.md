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
| Queue persistence + queries (claim, LLM slot, due, stale, prune) | `lib/data/sms_repository.dart` |
| Record shape + lifecycle states | `lib/models/sms_record.dart` |
| LLM mode resolution (proxy / BYOK / none) | `lib/services/llm/llm_mode.dart` |
| Install source (Play vs. sideload) | `lib/services/install_source.dart` |
| OpenRouter key validation before storage | `lib/services/llm/key_validator.dart` |
| Layer-1 sender/card gate (applied by the queue, not the classifier) | `lib/services/classification/sender_matcher.dart` |
| On-device / cloud classification entry points | `lib/services/classification/classifier.dart` |
| On-device model inference (TFLite/LiteRT) + tokenizer | `lib/services/classification/tflite_local_classifier.dart` |
| On-device accept/reject gate + field building | `lib/services/classification/local_gate.dart`, `lib/services/classification/local_parsers.dart`, `lib/services/classification/local_model.dart` |
| LLM provider for `byok` mode (no provider constructed in `none` mode) | `lib/services/llm/openrouter_provider.dart` |
| Persisting the classified result | `lib/services/finance/finance_writer.dart` |
| Post-drain relationship matchers (see [Matching](matching.md)) | `lib/services/finance/finance_matcher.dart` |
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
  `pawlet/debug` method channel (debug builds only). See the app README.

Capture then does, in order:

1. **Normalize** — trim the sender, convert CRLF/CR to LF and trim the body. Empty
   sender or empty body is dropped.
2. **Persist, deduped** — insert into the queue. A unique index on
   `(sender, timestamp, content)` means overlapping foreground / background / cold-start
   reads of the *same* SMS collapse to one row (duplicate inserts are ignored).
   Those reads all share one timestamp, so an exact key is enough here. The bulk
   inbox import cannot use it: it reads Android's `Telephony.Sms.DATE` (device
   receipt time) while the live listener stores the carrier's stamp from the
   PDU, and the two differ by around a second for the same message. The import
   matches on `(sender, content)` within `kSmsDedupWindow` instead.
3. **Kick off processing** — call the queue drain immediately.

A freshly captured row starts in status **`queued`**. Storage cleanup no longer runs on
capture — it moved into the drain pass as a throttled step (§3, §9).

## 2. The queue and a record's lifecycle

Every message is a row in `sms_records`, which doubles as the queue. Its `status` moves
through six states — note that **there are two distinct in-flight states**, one per row
and one global:

```
 queued ──claim (per row)──► processing ──take LLM slot (one)──► sending
                                 │                                 │
                                 └────────────────┬────────────────┘
                                                  ▼
                                   success  |  ignored  |  failure

 processing / sending ──► queued
   (deferred waiting for the LLM, rescheduled after a retryable failure, or
    reclaimed as stale after 3 min)
```

- **`queued`** — waiting to run. Also the resting state *between* retries (with a future
  `next_attempt_at`), and where a message that needs the LLM waits when the LLM is out of
  reach (§5).
- **`processing`** — claimed by one pass for on-device work (the Layer-1 gate and the
  local model). **Not exclusive:** any number of rows may be `processing` at once, across
  isolates — on-device work makes no network call and hits no rate limit, so serializing
  it would only let one slow LLM call stall messages the local model answers instantly.
- **`sending`** — an LLM call is in flight. **Exactly one row process-wide** holds this;
  it *is* the global LLM permit, and a row only enters it by being promoted out of
  `processing`.
- **`success`** — processed and written to a finance record (`transaction` or `bill`).
- **`ignored`** — processed but deliberately not a financial record. Terminal, but kept
  only briefly (§9). Invisible in History.
- **`failure`** — gave up (hit max attempts, or a fatal error). Shown in History with a
  short reason hint.

Both in-flight states render as the same **"Processing"** badge (`status_badge.dart`) —
the split is internal scheduling, not something the user needs to tell apart.

A **category label** (`transaction` / `bill`) is stored only on `success` rows.

Three internal, debug-only reason columns explain terminal non-success outcomes (see
`lib/models/sms_record.dart`):

- **`ignore_reason`** on `ignored` rows. The values this pipeline produces are `gated`
  (Layer-1 gate rejected it, nothing ran), `local_none` (the on-device model confidently
  said "not financial", no LLM call), `llm_none` (the LLM said "not financial"), and
  `no_record` (classified as financial but no row was written — missing metadata,
  unmatched card, or a duplicate). The enum holds two more values that only the bulk
  inbox import writes: `local_low_confidence` (the on-device model ran and was not
  confident enough) and `local_unavailable` (the model produced no prediction at all, so
  nothing judged the message). See [Backup & Restore](backup-restore.md).
- **`parse_source`** on processed rows — `local` (parsed on-device) or `llm` (fell back to
  the LLM). History shows a small, muted **"LLM"** marker on rows parsed by the LLM (i.e.
  where the on-device model was not confident); locally-parsed rows show nothing. Rows from
  before this column existed read as null.
- **`failure_reason`** on `failure` rows — `llm_error` (fatal), `retry_exhausted`, or
  `local_only` (no LLM exists and the on-device model could not build a record). The
  underlying error text is stored (truncated) in `last_error`; both are internal (read via
  ADB/debug), never surfaced in the UI. History shows only a short hint derived from
  `failure_reason`.

Queue queries that matter:

- **Due now** — `queued` rows whose `next_attempt_at` is null or already past, oldest
  SMS first (by receive time, not by retry time).
- **Claim** — a single atomic `queued → processing` update that returns true only for the
  winner. This is what makes concurrent isolates (UI + background) safe: two can't
  process the same row. It constrains *that row only* — other rows are free to be claimed
  at the same time.
- **Acquire the LLM slot** — promotes a row this caller already holds, `processing →
  sending`, and succeeds only when no other row is `sending`. This, not the claim, is
  what caps LLM concurrency at one call process-wide.
- **Reclaim stale** — a `processing` *or* `sending` row untouched for longer than the
  stale window is assumed orphaned (its isolate was killed mid-flight) and returned to
  `queued`.

Every write on a claimed row also carries a **fencing token** — the `updated_at` this
caller last wrote — and is rejected if the row no longer matches it. A holder frozen past
the stale window can have its row reclaimed and re-claimed by someone else; the token
makes its late writes no-ops instead of letting them overwrite the new owner. Both the
LLM-slot promotion and each guarded write rebase `updated_at`, so a caller carries the new
value forward. The token is re-checked immediately before the irreversible finance write,
which narrows the window in which a lost claim could strand a transaction on a row someone
else now owns down to the few milliseconds that write takes — deliberately narrowed rather
than closed (see the notes in `sms_repository.dart`).

## 3. Processing one message

A drain pass (`ProcessingService.process`) is **single-flight per isolate** (a re-entrant
call while one is running is ignored) and, before touching anything, requeues stale
in-flight rows. It then walks the due list and runs each through **three layers** — the
first two of which touch no network, so a pass is useful even with no connectivity at
all (§5):

1. **Claim** the row (`queued → processing`). Losing the claim means another isolate has
   it; skip it and carry on to the next row.
2. **Layer 1 — the sender/card gate** and **Layer 2 — the on-device model**, both local
   and free; then **Layer 3 — the cloud LLM**, only for what the first two could not
   settle:
   - **Layer-1 gate (local, free):** does the sender match one of your banks' matchers,
     or does the body contain one of your registered card numbers — in full, or masked
     down to three digits a side? If not, the message is **ignored with no LLM call** —
     this is what stops OTPs, promos, and personal texts from spending API quota. See
     [Matching](matching.md), which also explains why card digits are a credit card's
     *only* way through this gate.
   - **On-device model (local, free):** a message that passes the gate is first run through
     a bundled fused model (a small BERT-family encoder exported to TFLite and run via
     LiteRT — `tflite_local_classifier.dart`). In one pass it both classifies the message
     (transaction / bill / null) and extracts the numeric spans (amount, balance, amount
     due, statement period). The tokenizer reproduces the training tokenizer exactly (a
     golden parity test guards this).
     
     **With an LLM** (gated mode), the result is accepted on-device only when it is
     confident (`local_gate.dart`):
     - the classifier confidence AND the weakest extracted-span confidence (NERc) both clear
       a threshold; a confident `null` is ignored locally without any call;
     - a transaction must carry an amount span, a bill an amount-due span;
     - the amount must parse to a number.
     
     Anything short of that (low confidence, a missing span, or the model failing to load)
     falls back to Layer 3.
     
     **With no LLM** (ungated mode), the two confidence thresholds are skipped — whatever
     prediction the model produced is accepted. The structural checks above still apply: a
     missing amount span, an unparseable number, or a foreign currency with no conversion
     path means there is no record to build, which is a fact about the message rather than
     a confidence judgement. A `null` label still means ignore.

     A bill's **statement period is optional**: the month/year is parsed from the
     extracted span by `local_parsers.dart` (3-letter and full month names with a
     4-digit year, the apostrophe form `Sep'26`, and numeric forms like `07-2026`
     or `2026-09`), but a missing or unparseable period does **not** reject the
     bill — it is stored with no month/year. A sender whose period format is not
     recognised therefore produces bills that are silently undated rather than
     deferred to the LLM, so new statement formats are worth checking against
     this parser.

     When multiple spans of the same field are emitted, the highest-confidence one wins;
     NERc is measured over *all* emitted spans. A row already flagged `needs_llm` (§5)
     skips this layer entirely — the model has seen that exact content and declined it,
     and `content` never changes.

     **Currency handling:** the reporting currency is fixed to BDT (Pawlet is
     Bangladesh-only). A BDT amount is stored as-is. A **USD** amount is converted to BDT
     **on-device** using a live rate fetched and cached for 24h from an online source
     (`exchange_rate_service.dart`, `open.er-api.com`); the converted BDT value is stored
     as the normalized amount while the original USD figure is kept alongside it. Any
     *other* foreign currency, or USD when no rate has been cached yet (e.g. first run with
     no network), still routes to Layer 3 (which performs the conversion). The rate is read
     once per drain pass and served from cache thereafter; **offline the pass serves
     whatever is cached rather than attempting a fetch it cannot complete** (the choice is
     made in `app_services.dart`), because a doomed request would only burn its timeout on
     a path an incoming SMS drives synchronously.
   - **Layer 3 — the fused LLM call (network):** only when an LLM exists (modes `proxy` or
     `byok`; see [LLM modes](llm-modes.md)). Reached only when neither local layer decided.
     It needs two things: connectivity, and the single global LLM slot (`processing →
     sending`). Missing either, the row is **deferred, not failed** — see §5. With both,
     the message goes to a *single* OpenRouter request carrying a static ordered fallback
     list of structured-output-capable models (from `SettingsRepository.defaultLlmModels`).
     The request uses strict structured output (`response_format: {type: json_schema,
     json_schema: <schema>}`) with `provider: {require_parameters: true}` so every
     fallback hop enforces the schema. OpenRouter tries the models in order server-side
     within the single request. One attempt, no internal retry loop — transient failures
     surface as exceptions for the queue to retry (§7).
     
     **With no LLM** (mode `none`), Layer 3 is skipped entirely — no provider is
     constructed, and an on-device rejection is terminal. The row is marked `failure` with
     `FailureReason.localOnly`, shown in Messages as "On-device parsing failed". This is
     recoverable via the Retry button already offered on every failure row.
3. **Write** (`FinanceWriter`) — persist the result in one DB transaction (balance update
   and row insert commit together or not at all). Returns the category label, or
   `ignored` when nothing was written. The claim is re-checked under its fencing token
   immediately before this, because the write is irreversible.
4. **Mark terminal** — `next_attempt_at` cleared, `processed_at` set. A written record →
   `success` with its category; an `ignored` label → status `ignored` with the matching
   `ignore_reason`.

**Only the LLM call is globally serialized.** All three isolates (main, background-SMS,
WorkManager) share one `sending` slot, so at most one LLM call runs at once; on-device
work is capped per-row only, so many messages can be gated and classified locally in
parallel while that call is in flight. Records are taken oldest-first (FIFO), and a pass
**never stops early**: a row another isolate holds, or one deferred because the LLM is out
of reach, says nothing about the rows behind it, which may still be resolvable entirely
on-device. Likewise a retryable failure is rescheduled to a future backoff and the pass
moves straight on. An orphaned in-flight row (its isolate died) is freed by the
stale-reclaim step (§2, *Reclaim stale*), and the reschedule always leaves a wake scheduled
while any row is in flight so the slot can't stall forever.

After the queue drains, deferred **relationship matchers** run once — `FinanceMatcher`
stitches each credit-card bill payment to the debit that funded it and to the bill it
settles, see [Matching](matching.md) — then the terminal-failure **count** is reconciled
into notifications, a **throttled prune** runs (§9), the **data-change token** is bumped
(see below), and the next background catch-up is (re)scheduled (§6).

### Keeping the UI fresh

Any pass that changed data increments a DB-backed change token
(`SmsRepository.bumpDataRevision`, an `app_meta` counter) — from *whichever* isolate ran,
so background work counts too. While the app is foreground, the UI polls that token every
couple of seconds (`DataRevisionSync` in `lib/state/providers.dart`, kept alive by
`RootShell`); the read is a single primary-key lookup, and when the token moves it bumps an
in-memory revision that History and Finance watch, so processed records surface — Queue →
History moves, balances, transactions — with no manual pull-to-refresh. The token lives in
the DB precisely because a background isolate can't signal the UI isolate's memory
directly. On resume the app also bumps the in-memory revision (`lib/app.dart`) for an
instant refresh after an app switch; a cold reopen reads fresh from the DB anyway.
Pull-to-refresh (§4) remains as a manual fallback.

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

**Processing is not all-or-nothing on connectivity.** The gate and the on-device model
need no network, so a pass runs offline and drains everything those two layers can
decide — gate misses become `ignored`, and a confident local verdict is written to a
finance record just as it would be online. Only Layer 3 needs the internet.

Being offline must also never *cost* a message an attempt. The guards:

- **The pass always starts.** `process()` does not check connectivity before reading the
  queue; every due record goes through Layers 1 and 2 regardless.
- **A message that needs the LLM but cannot reach it is deferred, not failed** — only when
  an LLM exists. It goes back to `queued`, **still due, with its `attempts` and
  `next_attempt_at` untouched** — waiting is not a failed attempt, so a message that
  arrives during an outage does not burn its retry budget before anything has actually
  tried it. The same path handles a row that is online but loses the race for the single
  LLM slot. With no LLM, there is nothing to defer to, so an on-device rejection is
  terminal (see Layer 3 above).
- **`needs_llm` remembers that verdict** — only when an LLM exists. A row deferred *after
  the model ran and declined it* is flagged, so later passes skip an inference whose
  answer is already known. The flag is **set once and never cleared** — `content` is
  immutable, so the verdict is stable. Precisely because it is permanent, it is **not**
  set when the model never produced a prediction at all (none is bundled, or the model
  failed to load or crashed): nothing judged that message, so writing it off would route
  it to the paid LLM forever, and a single failed load in a background isolate would do
  that to the entire backlog deferred during that pass. Such a row is simply deferred
  unflagged and its inference is retried next pass, which costs almost nothing — a model
  that failed to load stays failed for the isolate and returns immediately. Offline, a
  flagged row is skipped before it is even claimed; the Layer-1 gate still re-runs on it
  once online, so a bank deleted in the meantime is honoured then.
  
  **With no LLM**, the flag is never set — there is nothing to defer to, so setting it
  would strand the row. A row that already carries it (e.g. the user removed their key)
  is re-run through the ungated gate rather than skipped.
- **A deferred row does not block the queue.** The pass carries on to the rows behind it,
  which may still be locally solvable (§3).
- **A failure discovered to be offline is a transport drop, not an attempt.** If the LLM
  call fails and a recheck shows the device went offline, the row is released back to
  `queued` **with its `attempts` and `next_attempt_at` unchanged**. The backoff ladder is
  not advanced for something the network, not the server, broke.

Net effect: offline, locally-decidable messages land immediately, and only the ones that
genuinely need the cloud wait — fully intact — for the next pass with connectivity.

## 6. Reconnecting — what happens when the internet comes back

There is **no foreground "connectivity restored" listener**. (A connectivity stream
exists in `connectivity_service.dart` but is intentionally unused for triggering drains.)
Recovery comes from two mechanisms instead:

- **Network-constrained background catch-up (primary).** After every pass, the pipeline
  reschedules a *single* one-off WorkManager task — for the soonest queued attempt, or,
  while a row is still `sending` (the slot is held, so no LLM-bound row can run yet), for
  that in-flight row's **stale-reclaim time** — or cancels it entirely when the queue
  is empty. Waking at the reclaim time rather than the blocked rows' due-now time is
  deliberate: a due-now wake would schedule the catch-up at delay zero, which WorkManager
  re-runs back-to-back (each pass reschedules itself) — a livelock. For the same reason the
  task is enqueued with `ExistingWorkPolicy.keep`, so a catch-up already running (holding the
  slot mid-call) is never cancelled and re-enqueued. Crucially the task carries a
  **"network connected" constraint**, so an offline backlog schedules a catch-up at
  delay zero and the OS simply holds it until connectivity returns, then runs it. An idle
  app with an empty queue schedules nothing and never wakes.

  **The network constraint survives §5 deliberately.** A pass now does useful work
  offline, but nothing offline-resolvable depends on *this* task: an incoming SMS drives
  a pass inline, in the app or in the background-SMS isolate, the moment it arrives. What
  the catch-up backstops — retry backoff and a stale LLM slot — is the part that needs
  the network anyway, so gating it saves wakeups without delaying anything.
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
| On-device rejection with no LLM available | **fatal** | mark `failure` (`local_only`) immediately |

### The backoff ladder

`attempts` counts *real* attempts — neither an offline drop nor a deferral (§5) counts.
Each retryable failure increments it and schedules the next run:

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

This is the recovery path for a `local_only` failure: a message rejected in no-LLM mode
can be retried after the user adds a key, at which point the pipeline has an LLM and the
row is re-processed normally.

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
matters, since numbers can drift. Card-digit and relationship-matcher constants live in
[Matching](matching.md).

| Constant | Value | Defined in |
|---|---|---|
| Max attempts before giving up | 10 | `processing_service.dart` |
| Base backoff | 15s | `processing_service.dart` |
| Backoff multiplier | ×4 per attempt | `processing_service.dart` |
| Max single backoff step | 6h | `processing_service.dart` |
| Server-hint ceiling | 24h | `processing_service.dart` |
| Stale in-flight (`processing`/`sending`) reclaim window | 3 min | `processing_service.dart` |
| On-device accept threshold (class conf & NERc) | 0.90 | `local_model.dart` |
| On-device max sequence length | 128 tokens | `tflite_local_classifier.dart` |
| LLM single-attempt HTTP timeout | 2 min | `openrouter_provider.dart` |
| Ignored retention | 7 days | `sms_repository.dart` |
| Prune throttle gap | 24h | `sms_repository.dart` |

The stale window (3 min) is deliberately kept **above** the HTTP timeout (2 min) so a
genuinely slow in-flight call is never reclaimed as orphaned mid-flight — which would risk
double-processing across isolates.
