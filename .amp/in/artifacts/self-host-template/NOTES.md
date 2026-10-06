# Self-host template E2E notes

Revision: b53db94 (branch chore/self-host-template) plus uncommitted working-tree changes. Date: 2026-10-06.
All tokens and passwords below are synthetic. Nothing touched a remote Cloudflare account.

## Setup
- `bun run --cwd apps/web build`
- Scratch config: cp apps/worker/wrangler.self-host.example.jsonc apps/worker/wrangler.self-host.jsonc, with fake D1 id 00000000-0000-4000-8000-000000000001 and plan UUID 3f2a9c1e-5b7d-4e86-9a10-2c4d8e6f7a11.
- apps/worker/.dev.vars: HOWMUCH_API_TOKEN=synthetic-setup-token-0001
- `cd apps/worker && bunx wrangler d1 migrations apply halation --local --config wrangler.self-host.jsonc` (18 migrations applied)
- `bunx wrangler dev --local --test-scheduled --config wrangler.self-host.jsonc --port 8791`

## API checks (curl, wrangler dev local)
| Step | Expected | Observed |
|---|---|---|
| GET /health | 200 | 200 |
| GET /.well-known/apple-app-site-association and /apple-app-site-association (no HOWMUCH_APPLE_APP_IDS) | 404 | 404, 404 |
| POST /api/auth/setup, Bearer token, Origin match, currency_format iso_code "gbp" (lowercase) | 400 | 400 |
| POST /api/auth/setup with GBP currency_format + DD/MM/YYYY | 200 | 200, session cookie set |
| GET /v1/plans/<id>/settings with that session | GBP | iso_code GBP, example_format "£123,456.78", symbol "£" |
| POST setup again | 409 | 409 |
| GET /__scheduled?cron=0+15+*+*+* | materialisation | log {"event":"scheduled_materialization",...} 200 |
| GET /__scheduled?cron=5+16+*+*+* | materialisation | same event, 200; no "Unknown scheduled cron" |
| Restart with --var "HOWMUCH_APPLE_APP_IDS:PQ6U5ESLN2.sg.soon.howmuch, ,Other.id", GET AASA | JSON, empties dropped | 200 application/json {"webcredentials":{"apps":["PQ6U5ESLN2.sg.soon.howmuch","Other.id"]}} |

Early "Request was cancelled" lines in the wrangler log came from the readiness curl poll during start-up, not from the handlers.

## Web setup form (Playwright, Chromium, locale en-GB, timezone Europe/London)
Fresh local DB (.wrangler removed, migrations re-applied), same dev server. Steps: open /, heading "Set up Halation", fill Username synthuser, Password synthetic-password-15, Setup token synthetic-setup-token-0001, click Create account, wait for heading All Accounts.
Expected: plan settings GBP. Observed (GET /v1/plans/<id>/settings via the browser session): currency_format iso_code GBP, "£123,456.78", symbol_first true; date_format DD/MM/YYYY.
Screenshot: .amp/in/artifacts/self-host-template/all-accounts-after-setup-en-GB.png

## Regression test (fail then pass)
Test: apps/api/tests/d1.test.ts "Worker runs materialisation for any cron except the YNAB sync cron, which stays configurable".
Before the index.ts change: failed at the `0 15 * * *` call (promise rejected, "Unknown scheduled cron"). After: passes, along with the existing 5 16 * * * and transition read-only tests (one existing assertion changed: an unlisted cron in read-only mode now fails with the read-only message instead of "Unknown scheduled cron").

## Suite
bun test (root): 800 pass, 0 fail (before iOS engine regeneration; rerun recorded in the report). apps/worker typecheck and apps/web build pass. iOS engine regenerated with Bun 1.4.0 and `check` reports up to date.
