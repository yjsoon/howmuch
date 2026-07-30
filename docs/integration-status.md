# Integration Status

Last updated: 2026-07-30

- Local Bun/SQLite development and YNAB/CSV imports are retained.
- Hosted Worker composition is D1-only.
- Canonical fresh D1 schema includes ledger, scheduler, audit, atomic-write, import, and auth-ready tables.
- Existing D1 atomic write and lease tests remain the safety baseline.
- Reviewed APAC production and preview D1 databases are bound. Apply the canonical migration before each environment's first deployment.
- Runtime authentication remains a static bearer token; auth tables are foundation only.
