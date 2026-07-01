# HowMuch Web

Report-first dashboard for the HowMuch ledger. See `docs/frontend/brief.md` for the design brief.

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

- `/spending`, `/income`, `/net-worth`, `/age-of-money` — the four reports
- `/transactions` — editable register: click a row to change date, account, payee, category, memo, amount, and cleared status, or delete it; uncategorised rows get an inline category picker
- `/accounts` — account management: create with a starting balance, rename, close/reopen, and reconcile (posts a balance-adjustment transaction)
- `/manage` — category and group CRUD (with transaction reassignment on delete), payee renaming, YNAB/CSV imports, and the API token
- `/add` — mobile quick entry (posts to `/api/mobile/quick-entry`)

Filters (date range, accounts, categories, interval) live in the query string and carry across tabs.

## First run and auth

With an empty database the app shows an onboarding screen: import a full YNAB history with a personal access token, or create a first account and start clean.

If the server sets `HOWMUCH_API_TOKEN`, the app prompts for the token and stores it in `localStorage`, sending it as a bearer token with every request (also editable under Manage → Connection).
