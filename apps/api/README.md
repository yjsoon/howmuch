# HowMuch API

Shared ledger, import, report, and HTTP code for two runtimes: local Bun/SQLite and hosted Cloudflare Worker/D1. `/v1` is the YNAB-compatible surface; `/api` provides reports, imports, and quick entry.

```sh
bun run api:dev
bun test apps/api/tests
```

SQLite applies `migrations/001`–`012`; D1 applies `d1-migrations/0001_initial.sql` through `0009_account_reconciliation_assertions.sql`. The D1 payee schema deliberately permits distinct YNAB payee IDs to share a display name. The raw-object mirror preserves imported YNAB fields that are not yet normalised, including monthly targets, scheduled transactions, locations, and money movements. Imported rows remain immutable: category assignments, targets, and scheduled-transaction changes live in separate guarded overlays. Scheduled transactions support HowMuch-local CRUD plus explicit, idempotent Enter Now and bounded owner catch-up through the effective `/v1` view. Production also runs a separate, count-only cron materialiser at 00:05 `Asia/Singapore`: it is capped at 25 fair, re-evaluated occurrences, isolates bad schedules, and marks any non-zero failure count observable after valid work completes; preview has no cron. Account reconciliation has a read-only preview plus an exact, idempotent `POST /v1/plans/{plan_id}/accounts/{account_id}/reconcile` cutover write: the commit requires a statement date, integer statement balance, and `Idempotency-Key`, and must not be followed by a YNAB re-import. Browser authentication uses a secure session cookie, native clients use opaque bearer sessions, and plan membership is enforced at the HTTP boundary. `HOWMUCH_API_TOKEN` is retained for one-time owner setup and default-plan integrations.
