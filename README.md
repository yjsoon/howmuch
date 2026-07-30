# HowMuch

HowMuch is a personal ledger and reporting app with YNAB-compatible `/v1` APIs and native `/api` reports/imports.

Local development uses Bun and SQLite:

```sh
bun run demo:seed
bun run dev:stack
bun test
```

The hosted runtime is a Cloudflare Worker using fresh production and preview D1 databases. Static assets, bearer authentication, the custom domain, `workers_dev`, and the hourly scheduled YNAB sync remain configured. See [deployment](docs/deployment.md).

YNAB API and export imports remain available through `import:ynab` and `import:ynab-export`.
