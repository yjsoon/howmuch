# HowMuch

HowMuch is a personal ledger and reporting app for the parts of YNAB that are actually in use:

- Spending Breakdown by category
- Income vs Spending
- Net Worth with filtering
- Age of Money
- Transaction ingestion from OpenClaw-style sources

The API exposes a small YNAB-compatible `/v1` surface so existing ingestion scripts can target it with minimal changes, while native clients use `/api` routes for reports, imports, and quick entry.

Local development runs on Bun with SQLite. The hosted application runs as a
Cloudflare Worker with Neon Postgres and serves the React app from the same
origin. See [the deployment runbook](docs/deployment.md).

## Quick Start

```sh
bun run demo:seed
bun run dev:stack
```

`bun run demo:seed` writes a reusable demo ledger into `data/howmuch.sqlite` using [fixtures/demo-ledger.json](fixtures/demo-ledger.json). It is safe to rerun and gives web/mobile tracks meaningful report data without a real YNAB import.

`bun run dev:stack` starts a `tmux` session called `howmuch-dev` with the API in one window. If `apps/web` is present in the checkout, it starts the web dev server in a second window; otherwise it leaves a status window explaining that the web track has not been merged yet.

Attach to the session:

```sh
tmux attach -t howmuch-dev
```

## Local Backend Only

```sh
bun run api:dev
```

By default the API stores data at `data/howmuch.sqlite` and listens on port `8787`.

Useful environment variables:

- `HOWMUCH_DB_PATH`: SQLite path.
- `HOWMUCH_API_TOKEN`: bearer token. If unset, local development requests are allowed.
- `HOWMUCH_DEFAULT_PLAN_ID`: default plan id for native routes.

## Automatic YNAB Sync

When a YNAB personal access token is configured, the local Bun server checks
YNAB every hour. Production uses an hourly Cloudflare scheduled handler instead;
it stores the YNAB server-knowledge cursor in Postgres, rejects overlapping
runs with a database lease, and deduplicates Cloudflare retries by scheduled
timestamp. If the token is empty or unset, no sync runs.

- `HOWMUCH_YNAB_TOKEN`: YNAB personal access token. Empty/unset disables the sync.
- `HOWMUCH_YNAB_PLAN_ID`: YNAB plan (budget) id to sync. Optional when the token
  can only see one plan; required when it can see several.
- `HOWMUCH_YNAB_SYNC_INTERVAL_MS`: how often to check, in milliseconds. Defaults
  to one hour for the local Bun server and is clamped to a five-minute minimum so the sync cannot exceed
  YNAB's rate limit of 200 requests per token per rolling hour (each pass costs
  six requests, so even at the floor the sync uses at most 72 per hour). If
  YNAB ever returns 429 — for example because other apps share the token — the
  sync logs a warning and pauses for a full hour so the rolling quota can
  recover, and it warns when the token passes 90% of its quota.
- `HOWMUCH_YNAB_MIN_SIMILARITY`: safety threshold between 0 and 1, default `0.95`.
  Once the ledger already holds YNAB-imported transactions, a sync pass only
  applies when the fetched data is at least this similar (matched by
  transaction id, date, and amount) to what was previously imported. Wrong
  budgets, truncated responses, and bulk rewrites are skipped and recorded as a
  `skipped` import session instead of overwriting the ledger. The first sync
  into an empty ledger is never blocked.

## YNAB Migration

Preferred path: import directly from the YNAB API with a personal access token.

```sh
bun run import:ynab --list-plans
bun run import:ynab --plan-id <ynab-plan-id> --db data/howmuch-real.sqlite
```

If a logged-in YNAB web session is available but a token is not, use the official web export fallback:

```sh
bun run import:ynab-export -- --zip "/path/to/YNAB Export - Actual Budget as of 2026-06-11 00-25.zip" --db data/howmuch-real.sqlite
```

Both importers create a backup before overwriting an existing SQLite file and print imported counts. Full workflow details live in [docs/ynab-migration.md](docs/ynab-migration.md).

## Smoke Check

```sh
bun run smoke
```

This boots the API against a temporary seeded database and checks:

- `/health`
- `/v1/user`, `/v1/plans`, `/v1/plans/{id}/accounts`, `/v1/plans/{id}/categories`, `/v1/plans/{id}/transactions`
- `/api/reports/spending-breakdown`
- `/api/reports/net-worth`
- `/api/mobile/quick-entry`

## Test Suite

```sh
bun test
```

Postgres and deployment verification commands:

```sh
bun run baseline:sqlite --output data/migration-baseline.json
DATABASE_URL='<Postgres URL>' bun run api:migrate:postgres
DATABASE_URL='<Postgres URL>' bun run migrate:neon -- --sqlite data/howmuch-real.sqlite
DATABASE_URL='<Postgres URL>' bun run verify:postgres-reports -- --baseline data/migration-baseline.json
DATABASE_URL='<Postgres URL>' bun run verify:postgres-api
DATABASE_URL='<Postgres URL>' bun run verify:scheduled-sync
cd apps/worker && bun run typecheck && bun run build
```

## Integration Status

The current backend/web/mobile convergence checklist lives in [docs/integration-status.md](docs/integration-status.md).
