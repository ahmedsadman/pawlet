# Meowni

Meowni is an on-device Android app that turns your bank SMS into a personal-finance
dashboard — transactions, bills, balances, spending trends. It runs with **no backend**:
everything happens on the phone. The only network calls are to a large language model
(OpenRouter's free models) to read each message.

## What it does

The phone receives bank SMS all the time — debits, credits, credit-card statements, OTPs,
promotions. Meowni watches those messages, works out which ones describe real money movements,
pulls the numbers out of them, and keeps a running picture of your finances. All of the storage,
matching, and aggregation happens locally in an on-device database.

## How it works (high level)

The pipeline is a queue. Every incoming message is saved first, then processed one step at a
time so nothing is lost if the phone is offline or the model is rate-limited.

1. **Capture** — an incoming SMS is persisted immediately into a local queue. Capture and
   processing are separate, so a message is never dropped just because processing failed.

2. **Sender gate (local, free)** — before spending any LLM call, Meowni checks whether the
   message could plausibly be from one of *your* banks. You add banks from a curated catalog;
   each bank carries a set of internal matcher strings. A message passes the gate if one of
   those matchers appears in the sender, or if the message body contains one of your registered
   credit-card numbers. Anything that fails the gate is marked *ignored* and never reaches the
   model. This is what keeps promotions, OTPs, and personal texts from wasting API calls.

3. **Understand (one LLM call)** — a message that passes the gate goes to a single fused
   model call. In one round-trip the model both **classifies** the message (transaction, bill,
   or neither) and **extracts** its structured data (amount, balance, direction, currency, and
   for bills the amount due and statement period). Currency conversion to your normalized
   currency happens here too. The call is atomic: the message only leaves the queue on a valid,
   fully-parsed response.

4. **Assign the bank deterministically** — the model is **not** asked which bank the message is
   from. Because the sender/card matchers are exact, Meowni assigns the bank itself: a
   credit-card number in the body wins; otherwise the single bank whose matcher hit the sender.
   An ambiguous sender is left unlinked rather than guessed. This removes a whole class of
   bugs where the model returned a near-miss bank name that failed to link.

5. **Write** — the result is written to the local database as a transaction or a bill. Bills
   are strict: one is only recorded when the message body actually contains a matching
   credit-card number. Deposit-account balances are updated from the message when the currency
   matches and the message is newer than the last known balance.

6. **Link related records** — separately, Meowni looks for relationships between records it
   already has: a debit on one account paired with a credit on another (a transfer), and a
   credit-card payment matched to the bill it paid. These run opportunistically over a bounded
   recent window, which is what powers the transfer icons and the paid/due status on bills.

The finance screens read straight from the local database, reproducing the same aggregations as
the original app (trends over rolling windows, monthly summaries, balances, spending breakdowns).

## Reliability and battery

- **Retry with backoff** — free models get rate-limited, so a failed message is requeued with a
  capped exponential backoff and retried later; only a genuinely fatal error (bad key) fails it
  outright. Everything is designed so processing can stop and resume at any point.
- **Adaptive background wakeups** — instead of waking on a fixed timer, Meowni only schedules a
  background catch-up when there is actually pending work (offline backlog or a retry waiting on
  its backoff), and cancels it when the queue drains. An idle app does no background work.
- **Incoming messages are handled immediately** while the app is alive; the background scheduling
  only covers the case where the phone is sitting untouched with a backlog.

## Design choices worth knowing

- **Categories are fixed** to *transaction* and *bill* — there is no free-form category list.
- **The LLM is behind a swappable interface** — the OpenRouter provider is one implementation;
  the rest of the app depends on the interface, not the vendor.
- **Money is stored as text and computed with decimal arithmetic** to avoid floating-point drift.
- **Banks are chosen from a catalog**, not typed freehand; matchers live internally so a
  non-technical user just picks their bank. Credit cards additionally need the card's first and
  last four digits.
- **Security**: a PIN plus optional biometric lock gates the whole app, re-locking on screen-off.

## Building

The only secret is the OpenRouter API key. There is **no in-app field for it** — the key is baked
in at **build time** via a `--dart-define` (a compiler flag), so whoever builds passes it and people
who install the app pass nothing. On first launch the app persists it to encrypted storage.

Get a free key at [openrouter.ai/keys](https://openrouter.ai/keys), then copy the example to
`dart_define.json` (gitignored) and fill it in `{"OPENROUTER_API_KEY": "sk-or-..."}`:

```bash
cp dart_define.example.json dart_define.json
```

**Local development** — pass the file to `flutter run` (needed only on first launch per install;
harmless to always pass, since a stored key takes precedence):

```bash
flutter run --dart-define-from-file=dart_define.json
```

**Release** — build once with the flag; the key is compiled in for every user. In CI, pass a
pipeline secret inline instead of committing the file:

```bash
flutter build appbundle --dart-define-from-file=dart_define.json               # local
flutter build appbundle --dart-define=OPENROUTER_API_KEY="$OPENROUTER_API_KEY" # CI
```

No key in a client binary is truly secret, and a single baked-in key means every user shares one
OpenRouter account (its rate limits and billing) — fine for a personal/sideloaded build, but for a
public release run a backend proxy that holds the key, or add a per-user "bring your own key" flow.

## Debug SMS injector

Physical (non-rooted) devices can't have a fake `SMS_RECEIVED` delivered over adb, which makes
it hard to exercise the pipeline without waiting for a real bank message. Debug builds therefore
ship a **debug-only injector** that feeds a fake message straight into the same code path a real
incoming SMS would take.

It is compiled in only when `kDebugMode` / `BuildConfig.DEBUG` is true, so it is **never present
in a release build**. Debug builds also use a `.debug` application-id suffix and the label
"Meowni Debug", so they install alongside a release build.

**How it works:** a debug-only broadcast receiver listens for the action
`com.meowni.meowni.INJECT_SMS`, reads `sender` and `content` string extras, and forwards them
over the `meowni/debug` method channel to the Dart side, which pushes them into the normal
"incoming raw SMS" entry point. From there they queue, gate, get classified, and get written
exactly like a real message.

### Using it

1. Build and install a debug build on the device, and make sure the app is in the foreground
   (the channel handler is installed when the UI starts).
2. For the injected message to do anything past the gate, the matching bank must already be
   added in-app (e.g. add "EBL" before sending an `EBL` message), and an OpenRouter API key
   must be provisioned at build time (see [Building](#building)).
3. Broadcast a fake message with adb:

```bash
adb -s <device> shell "am broadcast \
  -a com.meowni.meowni.INJECT_SMS \
  -p com.meowni.meowni.debug \
  --es sender 'EBL' \
  --es content 'Cash withdrawal of BDT 5000.00 from ATM. Available Balance: BDT 152300.00'"
```

**Quoting gotcha:** wrap the whole `am broadcast ...` command in one set of double quotes and use
single quotes around any extra value that contains spaces (like a `'City Bank'` sender). Without
the inner quotes the remote shell splits the value on the space and the extra is lost, so the
receiver silently drops the message.

### Inspecting the result

There is no sqlite CLI on a stock device, so pull the database and read it on the host:

```bash
adb -s <device> exec-out run-as com.meowni.meowni.debug cat databases/meowni.db > /tmp/meowni.db
python3 - <<'PY'
import sqlite3
db = sqlite3.connect('/tmp/meowni.db')
for row in db.execute("select id, sender, status, category from sms_records order by id"):
    print(row)
PY
```

Processing is asynchronous (it makes a network call), so give it a few seconds after injecting
before pulling the database.
