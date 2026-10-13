# Pairing Review

Suggests transaction pairs for the user to confirm: money moved between deposit accounts (internal transfers) and bank debits that paid a credit card but fell outside the automatic 15-minute pairing window or tied inside it. Suggestions are computed on read and never stored; only "No" answers are persisted.

Implementation lives in `lib/services/finance/pairing_suggester.dart` (finding candidates), `lib/services/finance/pairing_actions.dart` (applying answers), `lib/models/finance/pairing_suggestion.dart` (the pair model), `lib/state/pairing_providers.dart` (Riverpod wiring), `lib/ui/pairing_review_page.dart` (the deck screen), `lib/ui/widgets/finance/pairing_card.dart` (the swipeable review card), `lib/ui/widgets/finance/review_entry_card.dart` (the peach prompt on the Finance page), and `lib/ui/pairing_prompt_listener.dart` (the floating prompt).

## What gets suggested

Two kinds of pairs, both drawn from transactions that the automatic matcher (see [Matching](matching.md)) left unpaired:

- **Internal transfers** — an `expense` on one deposit account and an `income` on another deposit account. The user is asked whether this is the same money movement.
- **Card payments** — a bank `expense` debit and a credit-card `transfer` row (the "payment received" record) that are more than 15 minutes apart, or that fell inside the 15-minute window but tied (ties are never auto-paired).

Every candidate goes into one global pool, sorted by time gap (smallest first), then amount difference, then id. Pairs are taken greedily so each transaction appears in at most one suggestion. Each card notes how many other candidates also matched one of its legs but were not suggested.

## Storage

Suggestions are **computed fresh on every read** — they are never stored. This means a deleted, retyped, or auto-paired transaction can never leave a stale card behind.

Only the user's **"No" answers are stored**, in the `pairing_rejections` table (schema v9). Each rejection is identified by the two transaction ids (ordered low, high) and carries an `expires_at` timestamp set to 30 days after the pair's newer leg. Expired rejections are deleted by `SmsRepository.pruneIfDue` (see [Message pipeline](message-pipeline.md) §9), which shares its once-a-day throttle.

The schema is in `lib/data/database.dart`; pruning is in `lib/data/sms_repository.dart`.

## Matching rules

Both kinds use a time window and an amount tolerance. A pair is suggested only when:

- both legs share the same currency,
- the time gap between the two legs is within the window,
- the amount difference is within the tolerance,
- the newer leg is at most 30 days old (the look-back bound),
- neither leg is already paired (`paired_with_id IS NULL`),
- the user has not rejected this pair (not in `pairing_rejections`).

### Constants

Snapshot — verify against the named source.

| Constant | Value | Source |
|---|---|---|
| Window between legs | 96 h | `pairing_suggester.dart` |
| Look-back (newer leg) | 30 days | `pairing_suggester.dart` |
| Transfer amount tolerance | ±10.00 | `pairing_suggester.dart` |
| Card-payment amount tolerance | ±1.00 | `pairing_suggester.dart` (reuses `FinanceMatcher.tolerance`) |

The 96-hour window covers transfers and card payments whose two sides are reported days apart (an inter-bank credit can land well after the debit). The 30-day look-back keeps the review to recent activity, so importing years of old SMS history does not flood the deck.

## What happens on accept

Accepting a suggestion pairs the two legs:

- **Transfer:** both rows become `transfer` (changing the expense and income types) and point at each other via `paired_with_id`. Transfers are excluded from totals on the Finance page.
- **Card payment:** same as the automatic pairing in [Matching](matching.md). The bank leg takes the card leg's bill if it is already linked; otherwise the card payment is linked to its matching bill straight away (which gives both legs the bill). The bank leg is retyped to `transfer` and both rows point at each other.

If either leg changed since the suggestion was built (e.g. a background pass auto-paired it), the accept writes nothing and returns null.

A **snackbar with an Undo button** appears after every saved answer. Undo reverses an accept only while the two legs still point at each other. Undoing a card payment always clears the bank leg's bill, but clears the card leg's bill and the bill's `paid_at` only when this accept made that link (not when the card was already bill-linked beforehand).

## What happens on reject

Rejecting a suggestion writes a row to `pairing_rejections` with `expires_at` set to the newer leg's date plus 30 days (the look-back duration). The rejection is a no-op for the two transactions themselves — they remain unpaired.

## UI

**Finance page entry card:** a peach card appears at the top of the Finance page while reviews are pending (`lib/ui/widgets/finance/review_entry_card.dart`). Tapping it opens the review deck.

**Floating prompt:** a "N pairings to review" pill appears on cold start and when a new suggestion appears mid-session, whichever tab is open (`lib/ui/pairing_prompt_listener.dart`). It hides itself after a few seconds; tapping it opens the review deck. It is drawn inside the app shell rather than as a system-wide snackbar, so the lock screen and any page opened on top always cover it. It is never shown while the app is locked, never while the review page is open, and not merely because the app resumed. "New" means a pair this app session has not shown before, not a higher count; a new pair arriving while the pill is up updates its count.

**Review deck:** one-at-a-time cards (`lib/ui/pairing_review_page.dart`, `lib/ui/widgets/finance/pairing_card.dart`). Each card shows both legs, the time gap, and the amount difference. The user taps Yes/No buttons or swipes right (Yes) or left (No). When hidden balances are enabled, the amount difference and the SMS texts are also hidden.

## Backup

`pairing_rejections` is an **optional backup table** — exported always, restored when present. See [Backup & Restore](backup-restore.md). Older backups without it restore fine (the table is cleared and no rows are re-inserted). Because rejections are time-bounded and re-computed on every suggestion read, losing them on restore is harmless: the same suggestions reappear and the user can reject them again.
