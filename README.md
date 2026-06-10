# HowMuch

HowMuch is a self-hosted personal ledger and reporting app for the parts of YNAB that are actually in use:

- Spending Breakdown by category
- Income vs Spending
- Net Worth with filtering
- Age of Money
- Transaction ingestion from OpenClaw-style sources

The API exposes a small YNAB-compatible `/v1` surface so existing ingestion scripts can target it with minimal changes, while native clients use `/api` routes for reports, imports, and quick entry.

## Local Backend

```sh
bun run api:dev
```

By default the API stores data at `data/howmuch.sqlite` and listens on port `8787`.

Useful environment variables:

- `HOWMUCH_DB_PATH`: SQLite path.
- `HOWMUCH_API_TOKEN`: bearer token. If unset, local development requests are allowed.
- `HOWMUCH_DEFAULT_PLAN_ID`: default plan id for native routes.

## Checks

```sh
bun test
```

