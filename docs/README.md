# Pawlet docs

Technical wiki for how the app behaves — written for **humans**, not machines. Although not targeted for
LLM/Coding Agent usage, these docs will be mostly maintained by LLM/agents for the humans. LLMs can
update these docs to provide the latest and accurate info

## Rules

**For LLMs / coding agents**

- **Do not use these docs as a source of truth.** They are human-oriented explanations and
  may lag behind the code. When reasoning about or changing behavior, read the actual
  source instead — the code is authoritative, this wiki is not.
- **Do not pull these files into context** to answer code questions or ground edits.
- Do not cite or quote this wiki as evidence for how the app works.

**For writing these docs**

- **Prefer file references over code.** Link a file by path (e.g.
  `lib/services/processing_service.dart`); code drifts, file structure rarely does.
- **Avoid line numbers** — they go stale fastest.
- **Add a code snippet only when absolutely necessary** (e.g. code blocks that words can't 
  capture cleanly, a generic command etc.). Keep it minimal.
- Put concrete numbers/constants in one clearly-labelled table marked as a snapshot, and
  name the source file, so a reader knows where to verify.

## Contents

- [Message pipeline](message-pipeline.md) — how an SMS is received, queued, processed,
  and retried, including offline, reconnect, and backoff behavior.
- [Backup & Restore](backup-restore.md) — exporting all local data to a JSON file and
  restoring it (replace-all, IDs preserved), including the expected file format.

## RED FLAGS - STOP

| Red Flag | Solution |
|---|---|
| Using the docs as source of truth | Code is authoritative — read it directly. |
| Using line numbers while writing docs | Line numbers go stale first — copy over the code snippet. |
