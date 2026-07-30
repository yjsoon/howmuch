# HowMuch API

Shared ledger, import, report, and HTTP code for two runtimes: local Bun/SQLite and hosted Cloudflare Worker/D1. `/v1` is the YNAB-compatible surface; `/api` provides reports, imports, and quick entry.

```sh
bun run api:dev
bun test apps/api/tests
```

SQLite applies `migrations/001`–`004`. A fresh D1 applies only `d1-migrations/0001_initial.sql`. Authentication still uses a static bearer token, while users, identities, sessions, and plan memberships are ready in both schemas.
