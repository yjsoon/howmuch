# HowMuch Web

Ledger and Reflect dashboard for the HowMuch web app. See `docs/frontend/brief.md` for the design brief.

## Development

```sh
bun install        # from the repo root
bun run api:dev    # start the API on :8787
cd apps/web && bun run dev
```

The dev server runs on `:5173` and proxies `/api` and `/v1` to the API. Point it elsewhere with `HOWMUCH_API_URL=http://host:port`.

## Build

```sh
cd apps/web && bun run build
```

Typechecks then emits a static bundle to `dist/`.

## Routes

- `/` and unknown paths redirect to All Accounts (`/transactions?range=all&accounts=all`)
- `/spending`, `/income`, `/net-worth`, `/age-of-money` — the four Reflect reports
- `/transactions` — register with search and drill-down from reports
- `/scheduled` — recurring transactions
- `/settings` — Settings hub (API tokens, Rewards import)
- `/api-tokens` — personal API tokens
- `/import/rewards` — Rewards Tracker settings import
- `/add` — mobile quick entry (posts to `/api/mobile/quick-entry`)

Filters (date range, accounts, categories, interval) live in the query string and carry across tabs.
