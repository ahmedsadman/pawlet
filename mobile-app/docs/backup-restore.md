# Backup & Restore

Pawlet keeps everything on-device. **Backup & Restore** (Settings → Data) lets you
move that data off the phone as a single JSON file and load it back later — onto the
same device or a fresh install.

- **Backup** writes a JSON file and hands it to the Android share sheet (save to
  Drive, send to yourself, etc.).
- **Restore** reads a JSON file you pick, **replaces everything** currently on the
  device with the file's contents, then asks you to restart.

Implementation lives in `lib/services/backup_service.dart` (serialize + validate +
restore), `lib/data/settings_repository.dart` (the settings half), and
`lib/ui/backup_restore_page.dart` (the screen).

## Importing existing messages

Pawlet only sees SMS that arrive while it is installed, so a fresh install starts
empty even on a phone with years of bank messages behind it. **Import existing
messages** reads the device inbox once and back-fills from it.

You are offered it automatically the first time the app is unlocked, and it lives
permanently under Settings → Data. Implementation is in
`lib/services/bulk_import/` (the inbox reader, the gate, the engine) and
`lib/ui/bulk_import_flow.dart` (the offer, progress and summary sheets).

### How this pass differs from the live pipeline

It does **not** use the normal queue. Messages are read, classified and written
one at a time while a progress window blocks the rest of the app, and the
foreground drain is paused for the duration. Imported messages are written
straight to a finished state and are never parked in the queue, so a background
catch-up running at the same time has nothing of theirs to pick up — which is
what makes the on-device-only promise hold even mid-import or after a crash.

- **On-device model only.** The pass never calls the LLM. Where the live pipeline
  would fall back to the cloud because the model wasn't confident, this one drops
  the message instead — which is what the offer warns about up front.
- **Only bank-looking messages cost anything.** A message whose sender matches
  none of your accounts and none of the built-in bank catalog is skipped without
  a database write, so an inbox full of OTPs and promotions stays out of Pawlet
  entirely.
- **Banks are created for you, cards are not.** When a message comes from a
  sender the built-in catalog recognises and the model confidently reads a
  transaction out of it, the deposit account is created on the spot. Credit cards
  are never created: a card is identified only by digits printed in the message
  body, so Pawlet would be guessing. Card messages are still classified as bills —
  they just have nowhere to land until you add the card yourself.
- **Relationships are matched at the end.** Transfer pairing and bill linking run
  once over everything the pass wrote, rather than per message. That sweep
  normally only looks at the last 45 days of records, which is right for live
  processing and useless for a back-fill, so the import widens it to reach back
  to the oldest record it imported. The matching rules themselves don't change:
  a payment still has to land within 45 days of its statement, and a card
  payment within 15 minutes of the bank debit that funded it — those windows are
  measured from each record's own date, so they work the same in 2024 as today.
- **Oldest first.** Messages are replayed in the order they were received, so a
  deposit's stored balance ends up at the newest figure rather than an arbitrary
  one.

### Running it more than once is safe

The pass is idempotent. It reuses the same identity key as live capture — sender,
received time and body text — so a message already in Pawlet is recognised and
skipped rather than imported twice. `transactions` and `bills` additionally allow
only one row per message, so even a race can't double-count.

Re-running is also *useful*, not just harmless. A message an earlier pass had to
drop **for a reason that a re-run could change** is retried — specifically a card
statement that had no matching card, and any message a pass was interrupted
partway through. So the intended recovery from the credit-card caveat is: add
your cards under **Manage Banks & Cards**, then run the import again. Anything
already saved stays exactly as it is.

Messages dropped because the model wasn't confident are *not* retried. The same
model reading the same text would reach the same verdict, so re-running skips
them rather than paying for the inference twice — which is why a second import
finishes far faster than the first.

### What the summary tells you

Two numbers: how many inbox messages were walked, and how many financial records
came out. The gap is normal and mostly consists of messages that were never bank
messages at all. The two caveats printed underneath are the ones worth acting on —
messages dropped for low confidence, and card messages skipped for want of a card.

Stopping mid-run keeps everything already written; the summary then reports only
the part that ran, and re-running picks up where it left off.

## What is and isn't included

Included:

- The four SQLite tables — `sms_records`, `banks`, `transactions`, `bills`.
- User settings (the finance-view preferences).

Deliberately excluded:

- **Secrets** — the app PIN and the OpenRouter API key. They live in encrypted
  storage (`SecureStore`), never in the JSON. After restoring onto a fresh device you
  re-set the PIN, and the key is re-provisioned out-of-band.
- **Operational metadata** — the `app_meta` table (e.g. the last-prune timestamp) and
  notification bookkeeping prefs. These are device-local runtime state, not user data.

## Restore is replace-all

Restore is **not** a merge. It wipes every row in the four tables and re-inserts the
file's rows **with their original IDs preserved**, all inside one database
transaction. Preserving IDs is what keeps cross-table references valid — a
transaction points at its backing message and bank, a bill at its message, a transfer
at its paired transaction. Settings are replaced too: any managed key absent from the
file is reset to its default.

Because the whole DB rewrite is one transaction, a failure part-way rolls back cleanly
— you never end up with half-restored data. Settings are applied *after* that
transaction commits (SharedPreferences has no shared transaction); they're
non-referential, so this ordering is safe.

## Validation before anything is touched

A picked file is **fully validated before a single row is written**, so a bad file is
a harmless no-op — your current data is untouched. Restore rejects, with a clear
error, any file that:

- isn't valid JSON,
- isn't a JSON object at the top level,
- carries a `pawlet_backup_version` other than the supported one,
- has no `database` object, or
- is missing any of the four tables, or has a non-list where a table's rows belong.

The validation is **structural**, not a deep schema check. Once the shape is valid,
rows are inserted as-is; a row with the wrong columns or types is caught by SQLite's
own constraints inside the transaction (which then rolls back), surfacing as a generic
"restore failed" rather than a format error.

## File format

The file is a UTF-8 JSON object with this shape:

```jsonc
{
  "pawlet_backup_version": 1,            // must match the supported version
  "exported_at": 1750000000000,          // epoch ms, informational only
  "database": {
    "sms_records":  [ /* row objects */ ],
    "banks":        [ /* row objects */ ],
    "transactions": [ /* row objects */ ],
    "bills":        [ /* row objects */ ]
  },
  "settings": {                          // optional; omit to reset all settings
    "hide_balance": true,
    "tx_sort": "amount"
  }
}
```

Rules that matter when reading or producing this file:

- All four `database` tables must be present, each an array (empty array is fine).
- Each row is a JSON object mapping **exact column name → value**. Column names must
  match the schema exactly; unknown columns are not tolerated (they'll fail the insert
  at restore time).
- Types follow SQLite affinity: `INTEGER` columns → JSON numbers, `TEXT` columns →
  JSON strings, nullable columns → `null` or omitted. `NOT NULL` columns must carry a
  value.
- `id` is included on every row and preserved verbatim. Cross-table references
  (`message_id`, `bank_id`, `paired_with_id`, `bill_id`) must line up with those IDs.
- The `settings` object accepts only the managed keys below; unknown keys and
  type-mismatched values are ignored, and a missing key resets to its default.
- `exported_at` and any extra top-level keys are ignored on restore.

### Table columns (snapshot)

Authoritative schema is `lib/data/database.dart` (`AppDatabase.createSchema`); this
table is a snapshot — verify there if precision matters.

**`sms_records`** — captured messages; doubles as the processing queue.

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER | primary key, preserved |
| `sender` | TEXT | required |
| `contact_name` | TEXT | nullable; legacy/unused — always null on new rows |
| `content` | TEXT | required; the message body |
| `timestamp` | INTEGER | required; received time, epoch ms |
| `status` | TEXT | required; one of `queued`, `sending`, `success`, `ignored`, `failure` |
| `attempts` | INTEGER | default 0 |
| `last_error` | TEXT | nullable |
| `updated_at` | INTEGER | default 0 |
| `next_attempt_at` | INTEGER | nullable |
| `category` | TEXT | nullable; `transaction` or `bill`, only on `success` rows |
| `processed_at` | INTEGER | nullable |
| `ignore_reason` | TEXT | nullable; internal |
| `failure_reason` | TEXT | nullable; internal |
| `parse_source` | TEXT | nullable; `local` or `llm` — which engine parsed the row |

**`banks`** — user's banks and cards.

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER | primary key, preserved |
| `name` | TEXT | required |
| `account_type` | TEXT | required; `deposit` or `credit` (default `deposit`) |
| `card_digits` | TEXT | nullable; set for credit cards |
| `last_balance` | TEXT | nullable |
| `last_balance_at` | INTEGER | nullable |
| `created_at` | INTEGER | required, epoch ms |
| `matchers` | TEXT | nullable; sender matchers, newline-joined |

**`transactions`** — one per financial message classified as a transaction,
plus user-entered manual transactions (which have no backing SMS).

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER | primary key, preserved |
| `message_id` | INTEGER | nullable; → `sms_records.id`; null for manual entries |
| `bank_id` | INTEGER | nullable; → `banks.id` |
| `paired_with_id` | INTEGER | nullable; → `transactions.id` (transfer pairing) |
| `bill_id` | INTEGER | nullable; → `bills.id` (card-payment ↔ bill) |
| `normalized_amount` | TEXT | required |
| `normalized_currency` | TEXT | required |
| `original_amount` | TEXT | nullable |
| `original_currency` | TEXT | nullable |
| `type` | TEXT | required |
| `date` | INTEGER | required, epoch ms |
| `created_at` | INTEGER | required, epoch ms |

**`bills`** — one per message classified as a bill/statement.

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER | primary key, preserved |
| `message_id` | INTEGER | required; → `sms_records.id` |
| `bank_id` | INTEGER | nullable; → `banks.id` |
| `normalized_total_due` | TEXT | required |
| `normalized_currency` | TEXT | required |
| `original_amount` | TEXT | nullable |
| `original_currency` | TEXT | nullable |
| `statement_period` | INTEGER | nullable, epoch ms |
| `paid_at` | INTEGER | nullable, epoch ms |
| `created_at` | INTEGER | required, epoch ms |

### Settings keys (snapshot)

Authoritative list is `lib/data/settings_repository.dart`. Only these keys are backed
up; anything else in `settings` is ignored.

| Key | Type | Meaning |
|---|---|---|
| `summary_range` | string | saved Finance summary range |
| `tx_range` | string | saved transactions range |
| `tx_types` | string | comma-joined transaction-type filter |
| `tx_sort` | string | transactions sort key |
| `hide_balance` | bool | mask monetary values |
| `tx_type_hint_seen` | bool | one-time hint dismissed |
| `history_hint_seen` | bool | one-time hint dismissed |

## After a restore

Visible finance/messages data is refreshed immediately, but some settings-derived
caches only fully re-read on launch — hence the "restart Pawlet" prompt. A message
that happened to be mid-send when the backup was taken restores as `sending`; the
queue's stale-reclaim returns it to `queued` on the next drain, so it isn't stuck.
