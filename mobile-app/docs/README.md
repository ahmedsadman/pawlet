# Pawlet app docs

How the Flutter app behaves, explained for humans. The code is authoritative: if a page and
the code disagree, trust the code.

## Contents

- [LLM modes](llm-modes.md) — the three runtime modes (proxy, bring-your-own-key,
  no-LLM), how they are resolved, and what happens when no LLM is available.
- [Message pipeline](message-pipeline.md) — how an SMS is received, queued, processed,
  and retried, including offline, reconnect, and backoff behavior.
- [Matching](matching.md) — which account owns a record (card-digit matching, including
  partially-masked cards) and which records belong together (transfer pairing, bill
  linking).
- [Backup & Restore](backup-restore.md) — exporting all local data to a JSON file and
  restoring it (replace-all, IDs preserved), including the expected file format, plus
  the one-off import that back-fills records from the messages already on the phone.
- [Local-model stats](model-stats.md) — how each live message's on-device verdict is
  counted once, and how proxy installs report the daily counts.
- [App updates](app-updates.md) — how Play installs are offered new versions in-app, the
  "Not now" snooze, and how to test an update for real.
