# Integration Status

Last updated: 2026-07-30

- Local Bun/SQLite development and YNAB/CSV imports are retained.
- Hosted Worker composition is D1-only.
- D1 migrations include the ledger foundation and active password/session authentication tables.
- Existing D1 atomic write and lease tests remain the safety baseline.
- Reviewed APAC production and preview D1 databases are bound. Apply the canonical migration before each environment's first deployment.
- Runtime authentication supports username/password sessions for web and iOS; the static bearer remains for setup and default-plan integrations.
