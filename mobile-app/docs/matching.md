# Matching

Two different questions, both answered by deterministic rules rather than the model:

- **Card-digit matching** — *which account owns this record?* Runs during processing, in
  `lib/services/classification/sender_matcher.dart`.
- **Relationship matchers** — *which records belong together?* Runs after the queue drains,
  in `lib/services/finance/finance_matcher.dart`.

Neither involves the LLM. The model classifies each SMS in isolation and extracts its
numbers; everything about *ownership* and *linkage* is decided in Dart afterwards.

## Card-digit matching

A credit card is stored with its number as two four-digit groups — the first four and the
last four — in the `card_digits` column, entered as two separate fields when you add the
card (`lib/ui/banks_page.dart`). Deposit accounts have none.

This matters more than it looks, because **a credit card is stored with no sender
matchers at all**. That is deliberate: if a card also matched on sender, an ordinary
non-card SMS from that bank would match both the card and the same bank's deposit account
and resolve as ambiguous. The consequence is that **finding the digits in the message body
is a credit card's only route through the layer-1 gate**. A card whose digits are never
found is invisible to the pipeline and its messages are discarded unread.

### Two matchers

**Strict.** Both stored groups must appear in the body in full, separated by at most a
short run of mask characters, digits, spaces or hyphens. This covers the common printed
forms — `4238****3241`, `4238 12 3241`, `4238-XXXX-XXXX-3241`, and the bare number.

**Loose.** Some banks expose only *three* digits per side (`000***111`). The loose matcher
handles those by pairing up the digit runs in the message and testing each pair:

- the leading run must be a prefix of the stored first four, or vice versa (so a six-digit
  BIN also fits);
- the trailing run must be a suffix of the stored last four;
- the gap between them must stay inside the window and must contain at least one mask
  character (`*`, `X`, `x`).

The mask requirement is what stops amounts and reference numbers from reading as cards —
without it, `Bal 1000 111.50` would look like a card to an account stored `1000|4111`.
Requiring a genuine prefix and suffix, rather than merely overlapping digits, is what
stops a card that differs only at the fourth digit from being claimed by its neighbour.

Pairing whole digit runs, rather than searching for one card-shaped pattern, is a
deliberate choice. A single pattern is scanned left to right and non-overlapping, so an
unrelated number sitting next to the card consumes the card's own digits and the real card
is never reconsidered — `Trx 500 000***111` would pair `500` with `000` and then give up.
Working from whole runs also means a leading group can never be read out of the middle of
a longer number.

**Out of scope:** messages that show only the trailing digits (`****1234`, `card ending
1234`). They are common, but four trailing digits alone are a weak signal, and supporting
them needs its own decision about attribution risk.

### Who wins when signals disagree

The two matchers are used with different strictness depending on what a mistake costs.

| Caller | Order | Why |
|---|---|---|
| Layer-1 gate (`classifier.dart`) | strict **or** loose, no tie-break | A false positive costs one wasted LLM call; a false negative discards a real bill unseen. |
| Transaction (`finance_writer.dart`) | exact card → single sender match → loose card | Eight matching digits outrank a sender; three per side do not. |
| Bill (`finance_writer.dart`) | exact card → loose card | A bill has no meaningful sender fallback. |

A **loose** match must be unique. If two cards both fit the visible digits, nothing is
attributed rather than guessing — the same posture `singleSenderMatch` already takes for
ambiguous senders. The consequence differs by row type: a transaction is stored with no
account linked, while a bill with no identified card is **dropped**, because a bill that
belongs to no card is meaningless.

The sender deliberately outranks a *loose* card match for transactions. A deposit SMS
printing a masked account number (`A/C 123***678 debited`) can resemble a card, and
attributing it to a credit card would silently stop that deposit's balance from updating,
since balances are not tracked for credit accounts.

Three visible digits discriminate less than four: two cards from the same issuer share
their leading digits, leaving the trailing three as the only real distinguisher. Trying
the exact form first, and refusing an ambiguous loose result, is what contains that.

## Relationship matchers

Once the queue is empty, `FinanceMatcher.runPending` sweeps *recently-created,
still-unmatched* rows and stitches related credit-card money movements together. These
reconstruct the links *between* records that were each classified in isolation.

They are **event-driven, not scheduled**: they run at the tail of every drain pass and on
resume, replacing what used to be periodic daemon threads. There is no matcher timer — the
only time values involved are the **matching windows** (how far apart two records may sit
and still count as the same money movement), not polling intervals.

Three passes run — bill linking runs in both directions — each match committed in **its own
DB transaction**, so a two- or three-row link is all-or-nothing. Any **ambiguous tie is
skipped** and left for manual reconciliation.

- **Transfer pairing** — a credit-card `transfer` (the bill payment the issuer received) is
  paired with the bank `expense` debit that funded it. The closest-in-time candidate wins.
  The debit is retyped to `transfer` and both rows point at each other via `paired_with_id`.
- **Bill linking** — a credit-card `transfer` is linked to the matching `bill` on that same
  card (credit accounts only), preferring a bill *received before* the payment and then
  closest in time. It sets `bill_id` on the transfer and its paired debit, and stamps
  `paid_at` on the bill. Running from **both** directions — payment→bill and bill→payment —
  means a late-arriving counterpart still links to whichever record showed up first.

The whole sweep is **look-back bounded to the bill window**: older rows can no longer
acquire a new counterpart, so they are skipped.

## Constants

Snapshot — verify against the named source.

| Value | Setting | Source |
|---|---|---|
| 4 digits | each stored card group, first and last | `sender_matcher.dart`, `banks_page.dart` |
| 3–6 digits | leading run the loose matcher accepts | `sender_matcher.dart` |
| 3–4 digits | trailing run the loose matcher accepts | `sender_matcher.dart` |
| 16 chars | widest gap between a card's two visible groups | `sender_matcher.dart` |
| ±1.00 | amount tolerance, both relationship passes | `finance_matcher.dart` |
| ±15 minutes | transfer pairing window | `finance_matcher.dart` |
| ±45 days | bill linking window, and the sweep's look-back bound | `finance_matcher.dart` |
