# HowMuch API

Shared ledger, import, report, and HTTP code for two runtimes: local Bun/SQLite and hosted Cloudflare Worker/D1. `/v1` is the YNAB-compatible surface; `/api` provides reports, imports, and quick entry.

```sh
bun run api:dev
bun test apps/api/tests
```

SQLite applies `migrations/001`–`005`; D1 applies `d1-migrations/0001_initial.sql` and `0002_password_auth.sql`. Browser authentication uses a secure session cookie, native clients use opaque bearer sessions, and plan membership is enforced at the HTTP boundary. `HOWMUCH_API_TOKEN` is retained for one-time owner setup and default-plan integrations.
