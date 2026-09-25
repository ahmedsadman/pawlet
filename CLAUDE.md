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

Found under `mobile-app/docs` directory. This is intended for humans, not LLM. **Do not read those to gather context**.

### When to update
- After completing execution of a plan
- After edits which changes an existing behavior

While updating, follow instructions of `mobile-app/docs/README.md`. Only focus on the docs' **correctness**. **We don't care
about omission of information** - unless the user specifically instructed to add the new info.

