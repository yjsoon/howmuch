# HowMuch API

This app is a Bun TypeScript API backed by SQLite. It has two route families:

- `/v1`: a narrow YNAB-compatible API for existing tools.
- `/api`: native reports, imports, and mobile quick entry.

Run locally:

```sh
bun run api:dev
```

The server creates the SQLite database and applies migrations on startup.

