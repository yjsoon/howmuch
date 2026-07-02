# HowMuch

HowMuch is a self-hosted personal ledger and reporting app for the parts of YNAB that are actually in use:

- Spending Breakdown by category
- Income vs Spending
- Net Worth with filtering
- Age of Money
- Transaction ingestion from OpenClaw-style sources

The API exposes a small YNAB-compatible `/v1` surface so existing ingestion scripts can target it with minimal changes, while native clients use `/api` routes for reports, imports, and quick entry.

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

## Web App

The web app (`apps/web`, `bun run dev:stack` or `cd apps/web && bun run dev`) covers day-to-day use:

- The four reports, with shareable URL filters.
- A YNAB-style register: an accounts rail with balances, per-account view with the Cleared + Uncleared = Working balance strip and a Reconcile button, inline Add Transaction (with "Save and add another"), outflow/inflow fields, a cleared toggle on every row, and an "N new transactions to approve" banner.
- Transfers from the payee field: type or pick `Transfer : {Account}` and both linked sides are created; deleting one side removes both.
- An editable register row: click any row to fix its date, account, payee, category, memo, amount, or cleared status; uncategorised rows get a "Needs a category" picker.
- Accounts: create with a starting balance, rename, close/reopen, and reconcile.
- Manage: category groups/categories (rename, hide, delete with reassignment), payee renaming, YNAB/CSV imports, and the API token.
- First-run onboarding: with an empty database it offers a YNAB token import or a fresh start.

## YNAB Migration

The fastest path is in the web app: onboarding (or Manage → Import) accepts a YNAB personal access token, lists your budgets, and imports the chosen one. Equivalent CLI, with backups and balance-parity reporting:

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

## Integration Status

The current backend/web/mobile convergence checklist lives in [docs/integration-status.md](docs/integration-status.md).
