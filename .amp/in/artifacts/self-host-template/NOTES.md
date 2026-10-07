# Self-host template E2E notes

Revision: 76f9b0f (branch chore/self-host-template) plus uncommitted working-tree changes. Date: 2026-10-06.
All tokens, passwords and IDs below are synthetic. Nothing touched a remote Cloudflare account; every wrangler command used `--local`.

## Setup (repeatable)
1. `bun run --cwd apps/web build`
2. `cd apps/worker && cp wrangler.self-host.example.jsonc wrangler.self-host.jsonc`, replacing the placeholders with D1 id 00000000-0000-4000-8000-000000000001 and plan UUID 3f2a9c1e-5b7d-4e86-9a10-2c4d8e6f7a11.
3. `echo HOWMUCH_API_TOKEN=synthetic-setup-token-0001 > .dev.vars`
4. `bunx wrangler d1 migrations apply halation --local --config wrangler.self-host.jsonc` (18 migrations)
5. `bunx wrangler dev --local --test-scheduled --config wrangler.self-host.jsonc --port 8791`
6. Browser steps: Playwright, Chromium (`/opt/pw-browsers/chromium`), timezone Asia/Singapore, the locale named per row.
Between runs the server was stopped and `.wrangler` deleted, then migrations re-applied (fresh DB). Scratch config, `.dev.vars` and `.wrangler` were deleted afterwards.

## Web setup form
| Run | Steps | Expected | Observed |
|---|---|---|---|
| (a) locale en-US, fresh DB | open `/`, read the Currency and Date format selects, change to SGD and DD/MM/YYYY, fill username synthuser, 15+ character password, setup token, click Create account | prefill USD and MM/DD/YYYY; plan stored as SGD, DD/MM/YYYY, "." decimal | prefill `USD MM/DD/YYYY`. `GET /v1/plans/<id>/settings`: iso_code SGD, example_format "$123,456.78", decimal_separator ".", group_separator ",", symbol_first true; date_format DD/MM/YYYY |
| (b) locale de-DE, fresh DB | open `/`, accept the prefill, create account | prefill EUR; plan EUR with "." decimal and symbol after | prefill `EUR DD/MM/YYYY`. Settings: iso_code EUR, example_format "123,456.78 €", decimal_separator ".", group_separator ",", symbol_first false, currency_symbol "€"; date_format DD/MM/YYYY |
| (b2) same DB, signed in via the UI, `/add` quick entry | create account "Cash" via API, type amount `12.50` and payee "Synthetic Cafe" in the form, save | persisted as 12500 milliunits | `GET /v1/plans/<id>/transactions`: amount -12500 (outflow default), payee_name "Synthetic Cafe" |

Screenshots (this folder): `setup-form-en-US.png` (before creating, after changing to SGD), `setup-form-de-DE.png` (prefilled EUR), `setup-form-en-US-after.png`, `setup-form-de-DE-after.png`, `quick-entry-de-DE.png`. `all-accounts-after-setup-en-GB.png` is from the earlier recording and is no longer representative.

## API checks (curl, wrangler dev local)
| Step | Expected | Observed |
|---|---|---|
| POST /api/auth/setup with Bearer token, EUR currency_format with decimal_separator "," and group_separator "." | 400 | 400 "currency_format or date_format is not valid"; no plan or user created (setup then succeeded in (b)) |
| GET /__scheduled?cron=10+16+*+*+* with no YNAB vars | materialisation | 200, log `{"event":"scheduled_materialization",...}` |

## Escape hatch (docs/self-hosting.md, run verbatim with `--local` and the synthetic ids)
The documented `UPDATE plans SET currency_format_json=..., date_format_json=..., updated_at=CURRENT_TIMESTAMP WHERE id=...` ran against the local D1 after (b): `success: true`. Then `SELECT currency_format_json, date_format_json FROM plans` showed the SGD JSON and `{"format":"DD/MM/YYYY"}`, and after restarting wrangler dev, `GET /v1/plans/<id>/settings` (signed in) returned iso_code SGD, "$123,456.78", symbol_first true. Previously it was EUR, so the UPDATE took effect.

## Cron regression test (fail then pass)
Test: apps/api/tests/d1.test.ts "Worker runs materialisation for any cron except the YNAB sync cron, which stays configurable". Added a case first: cron `10 16 * * *` with no YNAB token, plan id or HOWMUCH_YNAB_SYNC_CRON and read-only false, expecting `scheduled_materialization` and one materialised transaction.
Before the apps/worker/src/index.ts change: FAIL ("Expected promise that resolves, received promise that rejected", the YNAB sync crashed). After: pass, with the existing `5 16 * * *`, transition read-only and explicit `HOWMUCH_YNAB_SYNC_CRON` assertions unchanged.

## Suite
`bun test`: 801 pass, 0 fail. `cd apps/worker && bun run typecheck` and `bun run --cwd apps/web build` pass. iOS engine rebuilt with Bun 1.4.0 (the validator is bundled); `check` reports "The iOS engine is up to date."
