# HowMuch

HowMuch is a personal ledger and reporting app with YNAB-compatible `/v1` APIs and native `/api` reports/imports.

Public API documentation is available at [howmuch.soon.sg/docs](https://howmuch.soon.sg/docs). Its source is [the API contract](docs/api-contract.md).

Local development uses Bun and SQLite:

```sh
bun run demo:seed
bun run dev:stack
bun test
```

The hosted runtime is a Cloudflare Worker using production and preview D1 databases. The browser uses username/password login with an `HttpOnly` session cookie; iOS stores an opaque session token in Keychain. The static bearer token remains available for one-time account setup and default-plan integrations. Production is a one-time YNAB cutover: the imported source mirror is lossless and read-only, while HowMuch-owned category assignments, targets, and scheduled-transaction changes are stored separately. No recurring YNAB sync is configured. A HowMuch-only production cron enters due schedules daily at 00:05 Asia/Singapore; preview has no cron. See [deployment](docs/deployment.md).

YNAB API and export imports remain available through `import:ynab` and `import:ynab-export`.

The iOS register supports signed split allocations, including split transfers; duplicating a split for today creates fresh child lines rather than reusing the original IDs.
