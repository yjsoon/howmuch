# Integration Status

Last updated: 2026-06-10

This document tracks merge readiness across backend, web, iOS, importer, auth, and design. It is integration glue only, so open items owned by other tracks stay as TODOs rather than guessed implementations.

## Current State

| Track | Status | Notes |
| --- | --- | --- |
| Backend/API | In progress, usable locally | Bun API, SQLite migrations, YNAB-compatible `/v1`, native reports, CSV import, YNAB import route, and mobile quick-entry route are present. |
| Web | Pending merge into this worktree | `apps/web` is not present here yet. Claude Fable owns implementation and design direction in the main checkout. |
| iOS | Early planning only | `apps/ios/README.md` defines the initial API dependency, but no app scaffold is present in this worktree. |
| Demo data | Ready | `bun run demo:seed` loads [fixtures/demo-ledger.json](../fixtures/demo-ledger.json) into the default SQLite database. |
| Smoke test | Ready | `bun run smoke` exercises health, core `/v1` resources, representative `/api` reports, and mobile quick entry against a temporary seeded database. |
| Auth | Local-only shape exists | Static bearer token is supported; local development remains open if `HOWMUCH_API_TOKEN` is unset. No web or device auth UI is wired yet. |
| Design | Owned elsewhere | Design direction is defined in [docs/frontend/brief.md](frontend/brief.md); implementation is intentionally untouched here. |

## Ready Now

- `bun run demo:seed` for meaningful local data without a live YNAB import.
- `bun run api:dev` for backend-only development.
- `bun run dev:stack` for a tmux-based API plus web session once `apps/web` lands.
- `bun run smoke` for quick integration verification.

## Merge Checklist

- Backend
  - [x] API starts against SQLite and applies migrations automatically.
  - [x] Reports return seeded data for spending, income vs spending, net worth, and age of money.
  - [x] CSV import endpoint exists.
  - [ ] YNAB import flow verified against a real token and full-history import.
- Web
  - [ ] Merge Claude’s `apps/web` branch into the shared integration branch.
  - [ ] Confirm `apps/web/package.json` exposes `bun run dev`.
  - [ ] Verify the web dev server proxies `/api` and `/v1` to `:8787` as described in the brief.
  - [ ] Open the seeded data flow and confirm all four reports render with meaningful labels and totals.
- iOS
  - [ ] Scaffold the app target or import the current iOS branch.
  - [ ] Point quick entry to `/api/mobile/quick-entry` against the seeded local plan.
  - [ ] Confirm report screens can read seeded data without a YNAB migration.
- Importer
  - [x] CSV import route exists for fixture-style ingestion.
  - [ ] Decide whether demoing should use direct seed data, CSV import, or a captured YNAB fixture for parity testing.
  - [ ] Capture at least one real YNAB import verification run before release.
- Auth
  - [ ] Decide whether morning demo builds run tokenless on localhost or with a shared `HOWMUCH_API_TOKEN`.
  - [ ] Document where web and iOS should source that token if it is required before launch.
- Design and release
  - [ ] Merge the design/web track without overwriting root workflow scripts.
  - [ ] Run `bun run smoke` after each major merge.
  - [ ] Do one end-to-end morning-demo pass with seeded data and both API and web running together.

## Known Risks

- `apps/web` is absent in this worktree, so local convergence with the real web UI cannot be verified here yet.
- The YNAB import route exists but has not been exercised in this integration pass because no live token fixture is available in-repo.
- The demo seed uses direct repository writes for stable labels and categories; that is correct for local fixtures, but it does not replace importer parity testing.
