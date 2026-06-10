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
