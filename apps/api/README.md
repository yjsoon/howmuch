# HowMuch API

This package contains the shared HowMuch API handlers and ledger domain. It has
two runtime/storage combinations:

- Bun with local SQLite for development and imports.
- Cloudflare Workers with Neon Postgres for hosted preview and production.

It exposes two route families:

- `/v1`: a narrow YNAB-compatible API for existing tools.
- `/api`: native reports, imports, and mobile quick entry.

Run locally:

```sh
bun run api:dev
```

The local server creates the SQLite database and applies migrations on startup.
Postgres migrations are explicit:

```sh
DATABASE_URL='<Neon connection string>' bun run api:migrate:postgres
```

See [the deployment runbook](../../docs/deployment.md) for migration,
reconciliation, secrets, preview, and production procedures.
