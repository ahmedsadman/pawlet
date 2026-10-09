# Pawlet - CLAUDE.md

# Rules

## Git
- Never add Claude co-author info in Git commit messages
- Prefer granular commits to help with code reviews and history tracking
- Use these prefixes when writing commit messages:
   - fix: which represents bug fixes, and correlates to a SemVer patch.
   - feat: which represents a new feature, and correlates to a SemVer minor.
   - feat!:, or fix!:, refactor!:, etc., which represent a breaking change (indicated by the !) and will result in a SemVer major.
- Before opening a PR, always run lint and formatting equivalent of the current repo

## Docs

Found under three directories, one per component:
- `mobile-app/docs` — the Flutter app
- `server/docs` — the Go server
- `dashboard/docs` — the admin dashboard UI

These are intended for humans, not LLM. **Do not read those to gather context**, and do not cite them as evidence
for how the code behaves. They may lag behind the code; the code is authoritative.

### When to update
- After completing execution of a plan
- After edits which changes an existing behavior

Update the docs of the component you changed. Only focus on the docs' **correctness**. **We don't care about omission
of information** - unless the user specifically instructed to add the new info.

### How to write them
- **Prefer file references over code.** Link a file by path (e.g. `lib/services/processing_service.dart`); code
  drifts, file structure rarely does.
- **Never use line numbers** — they go stale fastest.
- **Add a code snippet only when absolutely necessary** (something words can't capture cleanly, a generic command
  etc.). Keep it minimal.
- Put concrete numbers/constants in one clearly-labelled table marked as a snapshot, and name the source file, so a
  reader knows where to verify.
- When adding a page, list it in that directory's `README.md`, which is the human-facing index.

