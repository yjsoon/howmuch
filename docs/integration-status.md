# Integration Status

Last updated: 2026-07-01

This document tracks merge readiness across backend, web, iOS, importer, auth, and design.

## Current State

| Track | Status | Notes |
| --- | --- | --- |
| Backend/API | Usable for daily migration | YNAB-compatible `/v1` reads and writes (transactions, accounts, category groups/categories, payees), native reports, CSV import, YNAB API import (fixed to the real `/budgets` paths), mobile quick entry, and `/api/bootstrap` for first-run detection. |
| Web | Usable for daily migration | Reports, editable register, accounts page (create/rename/close/reconcile), category and payee management, in-app YNAB and CSV imports, first-run onboarding, and bearer-token auth. Verified end-to-end in Chromium against seeded data. |
| iOS | App scaffold present | `apps/ios` contains the YNAB-style SwiftUI app; see `apps/ios/README.md`. |
| Demo data | Ready | `bun run demo:seed` loads [fixtures/demo-ledger.json](../fixtures/demo-ledger.json) into the default SQLite database. |
| Smoke test | Ready | `bun run smoke` exercises health, core `/v1` resources, representative `/api` reports, and mobile quick entry against a temporary seeded database. |
| Auth | Working end to end | Static bearer token via `HOWMUCH_API_TOKEN`; the web app prompts for it and stores it locally. Tokenless localhost remains open for development. |
| Design | Owned elsewhere | Design direction is defined in [docs/frontend/brief.md](frontend/brief.md). |

## Ready Now

- `bun run demo:seed` for meaningful local data without a live YNAB import.
- `bun run api:dev` for backend-only development.
- `bun run dev:stack` for a tmux-based API plus web session.
- `bun run smoke` for quick integration verification.
- Web onboarding: with an empty database, the app offers a YNAB token import or a fresh first account.

## Migration Checklist

- Backend
  - [x] API starts against SQLite and applies migrations automatically.
  - [x] Reports return seeded data for spending, income vs spending, net worth, and age of money.
  - [x] CSV import endpoint exists.
  - [x] YNAB importer targets the real API's `/budgets/...` paths (was `/plans/...`, which would 404 against api.ynab.com).
  - [x] Write routes for accounts, category groups, categories, and payees (create/rename/hide/close/delete with reassignment).
  - [ ] YNAB import flow verified against a real token and full-history import (needs a live token; the web flow surfaces errors inline).
- Web
  - [x] `apps/web` merged; `bun run dev` and `bun run build` work.
  - [x] Dev server proxies `/api` and `/v1` to `:8787`.
  - [x] All four reports render with seeded data.
  - [x] Register editing, quick categorisation, and deletion.
  - [x] Accounts: create, rename, close/reopen, reconcile via balance adjustment.
  - [x] Categories/payees management with delete-and-reassign.
  - [x] In-app YNAB token import and CSV paste import.
- iOS
  - [x] App scaffold present with quick entry and report/category screens.
  - [ ] Point quick entry at a deployed API and verify against real data.
- Auth
  - [x] Web sends `HOWMUCH_API_TOKEN` as a bearer token and prompts when the server requires one.
  - [ ] Decide the deployment story (see [docs/deployment.md](deployment.md)).

## Known Risks

- The YNAB API import has not been exercised against a live token in-repo; the paths now match the public API docs and the flow is covered by mocked tests, but do the first real import into a scratch database (`--db data/howmuch-real.sqlite`) and check the printed balance parity counts.
- Transfer pairs are linked on import; editing one side of a transfer in the web app deliberately locks amount/account/category to avoid desyncing the pair, and deleting a side is blocked in the editor.
- Split transactions keep their imported subtransaction lines; the web editor edits shared fields only and does not yet re-split.
