# Development

## Prerequisites

- Node 24
- A running pawlet-admin on `127.0.0.1:8092` (see `../../server/docs/admin.md`, "Running locally"),
  optionally against a `dev-seed` database

## Running the UI

```bash
npm install
npm run dev
```

Opens `http://localhost:5173`. The Vite config (`vite.config.ts`) proxies `/api` and `/healthz` to
the admin and keeps the Host header so the admin's same-origin check passes.

## Checks CI runs

`.github/workflows/dashboard-checks.yml` runs these on every change:

- `npm run format:check` — Prettier
- `npm run lint` — oxlint
- `npm run typecheck` — TypeScript
- `npm run test` — Vitest
- `npm run build` — production bundle

## How the UI ships

The production build embeds into the `pawlet-admin` binary. `server/admin.Dockerfile` builds
`dashboard/`, copies `dist/` into `server/internal/admin/web/dist/`, and the Go build embeds it.

Locally, `npm run build:embed` does the same: it builds the UI and runs `scripts/embed.mjs` to copy
the bundle into `server/internal/admin/web/dist/`, so `go run ./cmd/pawlet-admin` serves the real
UI. Only `.gitkeep` is committed in that directory.

## Where things live

| Path | What |
|---|---|
| `src/api/` | Contract types; mirror `server/docs/admin.md` API; the server is authoritative |
| `src/pages/` | Page components |
| `src/charts/` | Chart components |
| `src/components/` | UI components |
| `src/copy/stats.ts` | Stat tooltip copy |

All statistics are computed by the server (`server/internal/stats/`); the UI only formats and
plots.
