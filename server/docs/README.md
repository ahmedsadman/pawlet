# Pawlet server docs

How the Go server behaves, explained for humans. The code is authoritative: if a page and
the code disagree, trust the code.

## Contents

- [Auth flow](auth-flow.md) — how an install proves it is the genuine app on a genuine
  device, gets a session token, and uses it to classify messages; what each piece is for
  and what happens when a step fails.
