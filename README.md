# HowMuch

HowMuch is a personal ledger and reporting app with YNAB-compatible `/v1` APIs and native `/api` reports/imports.

Local development uses Bun and SQLite:

```sh
bun run demo:seed
bun run dev:stack
bun test
```

The hosted runtime is a Cloudflare Worker using production and preview D1 databases. The browser uses username/password login with an `HttpOnly` session cookie; iOS stores an opaque session token in Keychain. The static bearer token remains available for one-time account setup and default-plan integrations. The custom domain, `workers_dev`, and hourly scheduled YNAB sync remain configured. See [deployment](docs/deployment.md).

YNAB API and export imports remain available through `import:ynab` and `import:ynab-export`.
