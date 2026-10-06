# Pawlet app docs

How the Flutter app behaves, explained for humans. The code is authoritative: if a page and
the code disagree, trust the code.

## Contents

- [Message pipeline](message-pipeline.md) — how an SMS is received, queued, processed,
  and retried, including offline, reconnect, and backoff behavior.
- [Matching](matching.md) — which account owns a record (card-digit matching, including
  partially-masked cards) and which records belong together (transfer pairing, bill
  linking).
- [Backup & Restore](backup-restore.md) — exporting all local data to a JSON file and
  restoring it (replace-all, IDs preserved), including the expected file format, plus
  the one-off import that back-fills records from the messages already on the phone.
